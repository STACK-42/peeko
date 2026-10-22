import AppKit
import Foundation
import Observation

/// Owns today's record: ticks, credits app time, evaluates verifiers, rolls over at midnight, saves.
@MainActor
@Observable
public final class Scheduler {
    public static let tickInterval: TimeInterval = 10

    public private(set) var record: DayRecord
    public private(set) var lastSaveError: String?
    public var tasks: [TaskDefinition] = []
    public var githubUsername = ""

    /// Called once when an automatic task flips to done (never for manual taps).
    @ObservationIgnored public var onAutoComplete: (@MainActor (TaskDefinition) -> Void)?
    /// Called after every tick with that tick's activity sample.
    @ObservationIgnored public var onTick: (@MainActor (ActivitySample) -> Void)?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let frontmost: any FrontmostAppProvider
    @ObservationIgnored private let idle: any IdleTimeProvider
    @ObservationIgnored private let github: GitHubEventsClient
    @ObservationIgnored private let folders: FolderScanner
    // Kept for the scheduler's lifetime so their caches (poll intervals, ETags) survive between ticks.
    @ObservationIgnored private let fetcher: CachedFetcher
    @ObservationIgnored private let git = GitScanner()
    @ObservationIgnored private let reminders = RemindersReader()
    @ObservationIgnored private var lastSave: Date = .distantPast
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var activity: ActivityTracker
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    public init(
        store: Store,
        frontmost: any FrontmostAppProvider,
        idle: any IdleTimeProvider,
        github: GitHubEventsClient,
        fetcher: CachedFetcher = CachedFetcher(http: URLSessionHTTPClient()),
        calendar: Calendar = .current,
        now: Date = .now
    ) {
        self.store = store
        self.frontmost = frontmost
        self.idle = idle
        self.github = github
        self.folders = FolderScanner(store: store)
        self.fetcher = fetcher
        self.calendar = calendar
        self.activity = ActivityTracker(calendar: calendar)
        self.record = store.loadDay(DayKey.string(for: now, calendar: calendar))
    }

    public func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.tick() }
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.pause() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.pause() }
        observe(.default, .NSCalendarDayChanged) { $0.rolloverIfNeeded(now: .now) }

        Task { await tick() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    /// What went wrong with an online check's last request (feeds, Duolingo, LeetCode, Codeforces).
    public func onlineProblem(for task: TaskDefinition) async -> String? {
        guard let request = onlineRequest(for: task) else { return nil }
        return await fetcher.problem(for: request)
    }

    /// A GitHub token for the configured user, so private pushes count. nil or blank removes it.
    public func setGitHubToken(_ token: String?) async {
        await github.setToken(token)
    }

    /// The last GitHub problem for the configured username, if any.
    public func githubProblem() async -> String? {
        githubUsername.isEmpty ? nil : await github.problem(for: githubUsername)
    }

    public func pause() {
        activity.pause()
    }

    public func tick(now: Date = .now) async {
        rolloverIfNeeded(now: now)
        let sample = ActivitySample(
            now: now,
            frontmostBundleID: frontmost.frontmostBundleID(),
            secondsSinceInput: idle.secondsSinceLastInput(),
            // Only ask for the title (an Accessibility call) when a task filters on it.
            windowTitle: tasks.contains(where: \.needsWindowTitle) ? frontmost.frontmostWindowTitle() : nil
        )
        let credited = activity.record(sample, tasks: tasks, into: &record)
        let (spanStarted, spanMoved) = noteActivity(sample)
        let statusesChanged = await evaluateAutomaticTasks(now: now)
        // Extending an activity span alone saves at most once a minute.
        if !credited.isEmpty || statusesChanged || spanStarted || (spanMoved && now.timeIntervalSince(lastSave) >= 60) {
            save(now: now)
        }
        onTick?(sample)
    }

    /// Re-evaluates without crediting time, e.g. right after a task is enabled.
    public func refresh(now: Date = .now) async {
        rolloverIfNeeded(now: now)
        if await evaluateAutomaticTasks(now: now) { save() }
    }

    public func rolloverIfNeeded(now: Date) {
        let key = DayKey.string(for: now, calendar: calendar)
        guard key != record.day else { return }
        finalizeDay()
        record = store.loadDay(key)
    }

    /// Settles the day that's ending, even if the Mac slept through midnight:
    /// time-window tasks get their verdict, and limits still under their cap count as done.
    private func finalizeDay() {
        guard let end = DayKey.endOfDay(record.day, calendar: calendar) else { return }
        var changed = false
        for task in tasks {
            let settled: TaskStatus?
            switch task.type {
            case .activity:
                let status = ActivityWindowVerifier(definition: task, calendar: calendar)
                    .status(record: record, now: end.addingTimeInterval(1))
                settled = status == .pending ? nil : status
            case .appLimit:
                let status = AppLimitVerifier(definition: task).status(record: record)
                settled = status == .failed ? .failed : .done(at: end)
            default:
                settled = nil
            }
            if let settled, record.statuses[task.id] != settled {
                record.statuses[task.id] = settled
                changed = true
            }
        }
        if changed { save() }
    }

    public func setManual(_ done: Bool, for task: TaskDefinition, now: Date = .now) {
        guard task.type == .manual else { return }
        rolloverIfNeeded(now: now)
        record.statuses[task.id] = done ? .done(at: now) : nil
        save()
    }

    public func forget(taskID: String) {
        record.statuses[taskID] = nil
        record.accumulatedSeconds[taskID] = nil
        save()
    }

    /// Manual tasks are skipped: the record is their source of truth, and writing an
    /// evaluated copy back after an `await` could undo a tap made in between.
    private func evaluateAutomaticTasks(now: Date) async -> Bool {
        let day = record.day
        let context = VerifierContext(now: now, record: record)
        let environment = VerifierEnvironment(
            githubUsername: githubUsername, github: github, folders: folders, calendar: calendar,
            fetcher: fetcher, git: git, reminders: reminders
        )
        let evaluated = tasks.filter { $0.type != .manual }
        var results: [String: TaskStatus] = [:]
        for task in evaluated {
            guard let verifier = makeVerifier(for: task, environment: environment) else { continue }
            results[task.id] = await verifier.evaluate(context: context)
        }
        guard record.day == day else { return false }

        var changed = false
        var completed: [TaskDefinition] = []
        for task in evaluated {
            guard let status = results[task.id], record.statuses[task.id] != status else { continue }
            if status.isDone && record.statuses[task.id]?.isDone != true { completed.append(task) }
            record.statuses[task.id] = status
            changed = true
        }
        for task in completed { onAutoComplete?(task) }
        return changed
    }

    private func noteActivity(_ sample: ActivitySample) -> (started: Bool, moved: Bool) {
        guard sample.secondsSinceInput <= BreakTracker.activeWindow else { return (false, false) }
        var spans = record.activity ?? []
        let before = spans
        let started = ActivityLog.note(
            sample.now.addingTimeInterval(-sample.secondsSinceInput),
            in: &spans,
            notBefore: calendar.startOfDay(for: sample.now)
        )
        guard spans != before else { return (false, false) }
        record.activity = spans
        return (started, true)
    }

    private func save(now: Date = .now) {
        lastSave = now
        do {
            try store.save(record)
            lastSaveError = nil
        } catch {
            lastSaveError = "Couldn't save today: \(error.localizedDescription)"
        }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ action: @escaping @MainActor (Scheduler) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }
}
