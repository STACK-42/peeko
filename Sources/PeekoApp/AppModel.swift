import AppKit
import Foundation
import Observation
import PeekoCore
import EventKit
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

enum Mood {
    case dozing, looking, beaming

    init(_ status: TaskStatus) {
        switch status {
        case .pending, .failed: self = .dozing
        case .inProgress: self = .looking
        case .done: self = .beaming
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let presets: [TaskDefinition]
    let scheduler: Scheduler
    private let store: Store
    private let notifier = Notifier()
    @ObservationIgnored private let updater = Updater()
    private(set) var taskList: TaskList
    private(set) var settings: AppSettings
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var launchAtLoginStatus: SMAppService.Status = SMAppService.mainApp.status
    private(set) var accessibilityTrusted = Accessibility.isTrusted
    private(set) var githubProblem: String?
    /// Whether a GitHub token is saved in Keychain. The token itself never leaves Keychain and the client.
    private(set) var hasGitHubToken = false
    /// Last problem per online task (feeds, Duolingo, LeetCode, Codeforces), by task id.
    private(set) var onlineProblems: [String: String] = [:]
    private var localError: String?
    private var breakTracker = BreakTracker()
    private var pastDays = History(days: [:])
    private var pastDaysLoadedFor: String?
    private var breakMessageIndex = 0

    private static let lastNudgeDayKey = "lastNudgeDay"
    private static let launchAtLoginDefaultKey = "launchAtLoginDefaultApplied"
    private static let githubTokenAccount = "github-token"

    init(store: Store = Store(directory: Store.defaultDirectory), bundle: Bundle = .main) {
        self.store = store
        self.presets = Self.loadPresets(from: bundle)
        self.taskList = store.loadTaskList()
        self.settings = store.loadSettings()
        self.scheduler = Scheduler(
            store: store,
            frontmost: SystemFrontmostAppProvider(),
            idle: SystemIdleTimeProvider(),
            github: GitHubEventsClient(http: URLSessionHTTPClient())
        )
        scheduler.tasks = taskList.tasks
        scheduler.githubUsername = settings.githubUsername
        let token = Keychain.read(Self.githubTokenAccount)
        hasGitHubToken = token != nil
        scheduler.onAutoComplete = { [weak self] task in self?.notifyCompleted(task) }
        scheduler.onTick = { [weak self] sample in
            self?.nudgeIfDue(now: sample.now)
            self?.remindToTakeBreakIfDue(sample)
            Task { [weak self] in
                guard let self else { return }
                let problem = await self.scheduler.githubProblem()
                if problem != self.githubProblem { self.githubProblem = problem }
                var problems: [String: String] = [:]
                for task in self.tasks where task.type == .remoteCheck && task.params.source != "githubPush" {
                    if let p = await self.scheduler.onlineProblem(for: task) { problems[task.id] = p }
                }
                if problems != self.onlineProblems { self.onlineProblems = problems }
            }
        }
        Task { [scheduler] in
            await scheduler.setGitHubToken(token)
            scheduler.start()
        }
        loadHistoryIfNeeded()
        turnOnLaunchAtLoginOnce()
        Task { await refreshSystemStatus() }
    }

    /// Peeko only sees what happens while it runs, so it starts at login unless you turn that off.
    /// This runs once; after that, the Settings toggle is the only thing that changes it.
    private func turnOnLaunchAtLoginOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.launchAtLoginDefaultKey) else { return }
        if SMAppService.mainApp.status != .enabled {
            // Quietly retried next launch if it fails (say, run from a disk image).
            guard (try? SMAppService.mainApp.register()) != nil else { return }
        }
        defaults.set(true, forKey: Self.launchAtLoginDefaultKey)
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    var tasks: [TaskDefinition] { taskList.tasks }
    /// Your own tasks, plus any enabled task whose preset no longer ships (so it can still be removed).
    var customTasks: [TaskDefinition] {
        let presetIDs = Set(presets.map(\.id))
        return tasks.filter { $0.isCustom || !presetIDs.contains($0.id) }
    }
    var lastError: String? { localError ?? scheduler.lastSaveError }

    func status(for task: TaskDefinition) -> TaskStatus {
        scheduler.record.statuses[task.id] ?? .pending
    }

    func accumulatedMinutes(for task: TaskDefinition) -> Int {
        Int((scheduler.record.accumulatedSeconds[task.id] ?? 0) / 60)
    }

    func isSupported(_ task: TaskDefinition) -> Bool { isVerifiable(task) }

    /// The username a GitHub task will check, or "" if none is set.
    func githubUsername(for task: TaskDefinition) -> String {
        let own = task.params.username ?? ""
        return own.isEmpty ? settings.githubUsername : own
    }

    var doneCount: Int { tasks.filter { status(for: $0).isDone }.count }

    /// Tasks that can still happen today (not done, not already missed). Limits never need doing.
    var openCount: Int {
        tasks.filter {
            guard $0.type != .appLimit else { return false }
            switch status(for: $0) {
            case .done, .failed: return false
            case .pending, .inProgress: return true
            }
        }.count
    }

    var mood: Mood {
        if doneCount > 0 && openCount == 0 { return .beaming }
        let anyProgress = tasks.contains {
            switch status(for: $0) {
            case .done, .inProgress: true
            case .pending, .failed: false
            }
        }
        return anyProgress ? .looking : .dozing
    }

    func isEnabled(_ preset: TaskDefinition) -> Bool {
        tasks.contains { $0.id == preset.id }
    }

    // MARK: History

    static let historyDays = 35

    /// Past days come from disk (reloaded once per day); today is the live record.
    var history: History {
        var h = pastDays
        h.replace(scheduler.record)
        return h
    }

    var streak: Int { history.overallStreak(today: .now) }

    func loadHistoryIfNeeded() {
        let today = DayKey.string(for: .now)
        guard pastDaysLoadedFor != today else { return }
        pastDays = History.load(from: store, days: Self.historyDays, endingAt: .now)
        pastDaysLoadedFor = today
    }

    func exportData() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "peeko-export-\(DayKey.string(for: .now)).json"
        panel.allowedContentTypes = [.json]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PeekoExport.make(from: store).encoded().write(to: url, options: .atomic)
            localError = nil
        } catch {
            localError = "Couldn't export: \(error.localizedDescription)"
        }
    }

    /// What a preset needs from you before it can be switched on.
    enum Setup {
        case folder(message: String)
        case text(title: String, message: String, placeholder: String)
    }

    func setup(for preset: TaskDefinition) -> Setup? {
        let p = preset.params
        switch preset.type {
        case .folderActivity where (p.path ?? "").isEmpty:
            return .folder(message: "Pick your notes folder or Obsidian vault. Peeko only reads .md and .txt files in it.")
        case .gitCommits where (p.path ?? "").isEmpty:
            return .folder(message: "Pick the folder that holds your code. Peeko looks for git repos up to two levels down.")
        case .remoteCheck where p.source == "feed" && (p.url ?? "").isEmpty:
            return .text(title: "Which feed?", message: "Paste the RSS or Atom link of your blog, newsletter or channel.", placeholder: "https://yourblog.com/feed.xml")
        case .remoteCheck where p.source == "leetcode" && (p.username ?? "").isEmpty:
            return .text(title: "Your LeetCode username", message: "Your profile needs to be public. Peeko checks for an accepted solution today.", placeholder: "username")
        case .remoteCheck where p.source == "codeforces" && (p.username ?? "").isEmpty:
            return .text(title: "Your Codeforces handle", message: "Peeko checks for an accepted (OK) submission today.", placeholder: "handle")
        case .remoteCheck where p.source == "duolingo" && (p.username ?? "").isEmpty:
            return .text(title: "Your Duolingo username", message: "Your profile needs to be public. Peeko checks whether your streak was extended today.", placeholder: "username")
        default:
            return nil
        }
    }

    /// Switches a preset on with what `setup(for:)` asked for.
    func enable(_ preset: TaskDefinition, answer: String) {
        guard !isEnabled(preset) else { return }
        var task = preset
        switch preset.type {
        case .folderActivity:
            task.params.path = answer
        case .gitCommits:
            task.params.path = answer
            if (task.params.author ?? "").isEmpty { task.params.author = Self.gitEmail() }
        case .remoteCheck where preset.params.source == "feed":
            guard FeedVerifier.url(answer) != nil else {
                localError = "That doesn't look like a feed link (it should start with https://)."
                return
            }
            task.params.url = answer.trimmingCharacters(in: .whitespaces)
        case .remoteCheck:
            task.params.username = answer.trimmingCharacters(in: .whitespaces)
        default:
            break
        }
        taskList.tasks.append(task)
        saveTaskList()
    }

    /// Your git email, so "Committed code today" only counts your own commits.
    private static func gitEmail() -> String {
        guard let git = GitScanner.git else { return "" }
        return GitScanner.run(git, ["config", "--global", "user.email"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func requestRemindersAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToReminders()) ?? false
    }

    /// The enabled copy carries user choices (like the folder), so show that one when it exists.
    func enabledCopy(of preset: TaskDefinition) -> TaskDefinition? {
        tasks.first { $0.id == preset.id }
    }

    func setEnabled(_ preset: TaskDefinition, _ enabled: Bool) {
        if enabled {
            guard !isEnabled(preset) else { return }
            if preset.needsWindowTitle && !accessibilityTrusted { requestAccessibility() }
            taskList.tasks.append(preset)
        } else {
            taskList.tasks.removeAll { $0.id == preset.id }
        }
        saveTaskList()
    }

    func addCustomManualTask(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        taskList.tasks.append(.customManual(title: trimmed))
        saveTaskList()
    }

    func addCustomAppTimeTask(bundleID: String, appName: String, minutes: Int, limit: Bool = false) {
        guard minutes > 0 else { return }
        taskList.tasks.append(limit
            ? .customAppLimit(bundleID: bundleID, appName: appName, minutes: minutes)
            : .customAppTime(bundleID: bundleID, appName: appName, minutes: minutes))
        saveTaskList()
    }

    func remove(_ task: TaskDefinition) {
        taskList.tasks.removeAll { $0.id == task.id }
        saveTaskList()
        scheduler.forget(taskID: task.id)
    }

    func toggleManual(_ task: TaskDefinition) {
        scheduler.setManual(!status(for: task).isDone, for: task)
    }

    func rolloverIfNeeded() {
        scheduler.rolloverIfNeeded(now: .now)
        loadHistoryIfNeeded()
    }

    // MARK: Settings

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let usernameChanged = next.githubUsername != settings.githubUsername
        settings = next
        do {
            try store.save(settings)
            localError = nil
        } catch {
            localError = "Couldn't save settings: \(error.localizedDescription)"
        }
        if usernameChanged {
            scheduler.githubUsername = settings.githubUsername
            Task { await scheduler.refresh() }
        }
    }

    /// Saves the token to Keychain, or removes it when blank, and checks GitHub again with it.
    func setGitHubToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(Self.githubTokenAccount)
            hasGitHubToken = false
        } else {
            guard Keychain.save(trimmed, for: Self.githubTokenAccount) else {
                localError = "Couldn't save the GitHub token to Keychain"
                return
            }
            hasGitHubToken = true
        }
        localError = nil
        Task {
            await scheduler.setGitHubToken(hasGitHubToken ? trimmed : nil)
            await scheduler.refresh()
            githubProblem = await scheduler.githubProblem()
        }
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    func refreshSystemStatus() async {
        notificationStatus = await notifier.authorizationStatus()
        launchAtLoginStatus = SMAppService.mainApp.status
        accessibilityTrusted = Accessibility.isTrusted
    }

    func requestAccessibility() {
        Accessibility.requestTrust()
        accessibilityTrusted = Accessibility.isTrusted
    }

    var needsAccessibility: Bool { tasks.contains(where: \.needsWindowTitle) }

    func requestNotifications() async {
        _ = await notifier.requestAuthorization()
        await refreshSystemStatus()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            localError = nil
        } catch {
            localError = "Couldn't change launch at login: \(error.localizedDescription)"
        }
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    func revealDataFolder() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
    }

    // MARK: Notifications

    private func notifyCompleted(_ task: TaskDefinition) {
        notifier.post(
            id: "done-\(scheduler.record.day)-\(task.id)",
            title: "Peeko saw that!",
            body: "\(task.title) ✓  ·  \(doneCount) of \(tasks.count) done today"
        )
    }

    private func nudgeIfDue(now: Date) {
        let defaults = UserDefaults.standard
        let remaining = openCount
        guard EveningNudge.isDue(
            now: now,
            settings: settings,
            lastNudgeDay: defaults.string(forKey: Self.lastNudgeDayKey),
            remaining: remaining
        ) else { return }
        defaults.set(DayKey.string(for: now), forKey: Self.lastNudgeDayKey)
        notifier.post(
            id: "nudge-\(DayKey.string(for: now))",
            title: "Peeko's still peeking",
            body: remaining == 1 ? "1 task left today." : "\(remaining) tasks left today."
        )
    }

    private func remindToTakeBreakIfDue(_ sample: ActivitySample) {
        let interval = TimeInterval(settings.breakIntervalMinutes * 60)
        guard breakTracker.record(sample, interval: interval), settings.breakRemindersEnabled else { return }
        let messages = BreakMessages.all(minutes: settings.breakIntervalMinutes)
        let message = messages[breakMessageIndex % messages.count]
        breakMessageIndex += 1
        notifier.post(id: "break-\(sample.now.timeIntervalSince1970)", title: message.title, body: message.body)
    }

    private func saveTaskList() {
        scheduler.tasks = taskList.tasks
        Task { await scheduler.refresh() }
        do {
            try store.save(taskList)
            localError = nil
        } catch {
            localError = "Couldn't save tasks: \(error.localizedDescription)"
        }
    }

    private static func loadPresets(from bundle: Bundle) -> [TaskDefinition] {
        guard let url = bundle.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? Catalog.decode(data)
        else { return [] }
        return catalog.presets
    }
}
