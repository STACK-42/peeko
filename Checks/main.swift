import Foundation
import PeekoCore

// Run with `make check`. Exits non-zero on any failure.

var failures = 0

@MainActor func group(_ name: String) {
    print("\n\(name)")
}

@MainActor func check(_ ok: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    print(ok ? "  ✓ \(message)" : "  ✗ \(message)  (\(file):\(line))")
    if !ok { failures += 1 }
}

@MainActor final class FakeFrontmost: FrontmostAppProvider {
    var bundleID: String?
    var title: String?
    private(set) var titleRequests = 0
    init(_ bundleID: String?, title: String? = nil) { self.bundleID = bundleID; self.title = title }
    func frontmostBundleID() -> String? { bundleID }
    func frontmostWindowTitle() -> String? { titleRequests += 1; return title }
}

@MainActor final class FakeIdle: IdleTimeProvider {
    var seconds: TimeInterval
    init(_ seconds: TimeInterval) { self.seconds = seconds }
    func secondsSinceLastInput() -> TimeInterval { seconds }
}

actor FakeHTTP: HTTPClient {
    struct Reply { var status: Int; var body: String; var etag: String? }
    var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        let reply = replies.removeFirst()
        let headers = reply.etag.map { ["ETag": $0] } ?? [:]
        return (Data(reply.body.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: headers)!)
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

func offlineGitHub() -> GitHubEventsClient { GitHubEventsClient(http: FakeHTTP([])) }

func eventsJSON(_ events: [(String, String)]) -> String {
    "[" + events.map { #"{"type":"\#($0.0)","created_at":"\#($0.1)","id":"1"}"# }.joined(separator: ",") + "]"
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "Asia/Riyadh")!

@MainActor func at(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
}

let preview = "com.apple.Preview"
let read = TaskDefinition(
    id: "read-pdfs", title: "Read", type: .appTime,
    params: TaskParams(bundleIDs: [preview], minutes: 30, idleCutoffSeconds: 120), icon: "book"
)
let deepWork = TaskDefinition(
    id: "deep-work", title: "Deep work", type: .appTime,
    params: TaskParams(bundleIDs: ["com.microsoft.VSCode", "com.apple.Terminal"], minutes: 90), icon: "laptopcomputer"
)
let gym = TaskDefinition(id: "gym", title: "Gym", type: .manual, icon: "dumbbell")

@MainActor func sample(_ date: Date, _ front: String?, idle: TimeInterval = 5) -> ActivitySample {
    ActivitySample(now: date, frontmostBundleID: front, secondsSinceInput: idle)
}

@MainActor func tempStore() -> Store {
    Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent("peeko-checks-\(UUID())"))
}

// MARK: - ActivityTracker

group("ActivityTracker")
do {
    var tracker = ActivityTracker()
    var record = DayRecord(day: "2026-10-10")
    let t0 = at(10, 9, 0)

    tracker.record(sample(t0, preview), tasks: [read], into: &record)
    check(record.accumulatedSeconds["read-pdfs"] == nil, "first tick only starts the clock")

    tracker.record(sample(t0.addingTimeInterval(10), preview), tasks: [read], into: &record)
    check(record.accumulatedSeconds["read-pdfs"] == 10, "counts 10s when the app is in front and you're active")

    tracker.record(sample(t0.addingTimeInterval(20), preview, idle: 121), tasks: [read], into: &record)
    check(record.accumulatedSeconds["read-pdfs"] == 10, "doesn't count past the idle cutoff")

    tracker.record(sample(t0.addingTimeInterval(30), preview, idle: 119), tasks: [read], into: &record)
    check(record.accumulatedSeconds["read-pdfs"] == 20, "still counts while idle is under the cutoff")

    tracker.record(sample(t0.addingTimeInterval(40), "com.apple.Safari"), tasks: [read], into: &record)
    check(record.accumulatedSeconds["read-pdfs"] == 20, "doesn't count other apps")

    tracker.record(sample(t0.addingTimeInterval(40 + 2 * 3600), preview), tasks: [read], into: &record)
    check(record.accumulatedSeconds["read-pdfs"] == 30, "a 2-hour sleep gap is capped at 10s")

    tracker.pause()
    tracker.record(sample(t0.addingTimeInterval(9000), preview), tasks: [read], into: &record)
    check(record.accumulatedSeconds["read-pdfs"] == 30, "after pause() the next tick credits nothing")

    tracker.record(sample(t0.addingTimeInterval(8990), preview), tasks: [read], into: &record)
    check(record.accumulatedSeconds["read-pdfs"] == 30, "a clock going backwards credits nothing")

    tracker.record(sample(t0.addingTimeInterval(9000), preview), tasks: [read], into: &record)
    tracker.record(sample(t0.addingTimeInterval(9004), preview), tasks: [read], into: &record)
    check(record.accumulatedSeconds["read-pdfs"] == 44, "short ticks credit their real length")

    var record2 = DayRecord(day: "2026-10-10")
    var tracker2 = ActivityTracker()
    tracker2.record(sample(t0, "com.apple.Terminal"), tasks: [read, deepWork], into: &record2)
    tracker2.record(sample(t0.addingTimeInterval(10), "com.apple.Terminal", idle: 100), tasks: [read, deepWork], into: &record2)
    check(record2.accumulatedSeconds["deep-work"] == 10, "any of several bundle IDs counts; default cutoff is 120s")
    check(record2.accumulatedSeconds["read-pdfs"] == nil, "only matching tasks are credited")
}

// MARK: - AppTimeVerifier

group("AppTimeVerifier")
do {
    let verifier = AppTimeVerifier(definition: read)
    let now = at(10, 12, 0)
    var record = DayRecord(day: "2026-10-10")

    check(await verifier.evaluate(context: .init(now: now, record: record)) == .pending, "no time yet → pending")

    record.accumulatedSeconds["read-pdfs"] = 900
    check(await verifier.evaluate(context: .init(now: now, record: record)) == .inProgress(progress: 0.5), "15 of 30 min → 50%")

    record.accumulatedSeconds["read-pdfs"] = 1800
    check(await verifier.evaluate(context: .init(now: now, record: record)) == .done(at: now), "30 of 30 min → done")

    let earlier = at(10, 11, 0)
    record.statuses["read-pdfs"] = .done(at: earlier)
    check(await verifier.evaluate(context: .init(now: now, record: record)) == .done(at: earlier), "keeps the original done time")
}

// MARK: - Scheduler

group("Scheduler")
do {
    let store = tempStore()
    let front = FakeFrontmost(preview)
    let idle = FakeIdle(5)
    let start = at(10, 9, 0)
    let scheduler = Scheduler(store: store, frontmost: front, idle: idle, github: offlineGitHub(), calendar: calendar, now: start)
    scheduler.tasks = [read, gym]

    for i in 0...90 { await scheduler.tick(now: start.addingTimeInterval(Double(i) * 10)) }
    check(scheduler.record.accumulatedSeconds["read-pdfs"] == 900, "15 minutes of ticks → 900s")
    check(scheduler.record.statuses["read-pdfs"] == .inProgress(progress: 0.5), "status is in progress at 50%")

    scheduler.setManual(true, for: gym, now: start.addingTimeInterval(905))
    for i in 91...180 { await scheduler.tick(now: start.addingTimeInterval(Double(i) * 10)) }
    let doneAt = start.addingTimeInterval(1800)
    check(scheduler.record.statuses["read-pdfs"] == .done(at: doneAt), "30 minutes in Preview flips the task to done")
    check(scheduler.record.statuses["gym"]?.isDone == true, "ticks don't undo a manual tap")

    await scheduler.tick(now: start.addingTimeInterval(1810))
    check(scheduler.record.statuses["read-pdfs"] == .done(at: doneAt), "done time doesn't move on later ticks")

    let reloaded = store.loadDay("2026-10-10")
    check(reloaded.accumulatedSeconds["read-pdfs"] == 1810, "progress is saved to disk")

    scheduler.pause()
    await scheduler.tick(now: start.addingTimeInterval(1810 + 3600))
    check(scheduler.record.accumulatedSeconds["read-pdfs"] == 1810, "no credit for the tick after sleep")
}

group("Scheduler: midnight rollover")
do {
    let store = tempStore()
    let scheduler = Scheduler(store: store, frontmost: FakeFrontmost(preview), idle: FakeIdle(5), github: offlineGitHub(), calendar: calendar, now: at(10, 23, 59, 40))
    scheduler.tasks = [read, gym]
    scheduler.setManual(true, for: gym, now: at(10, 23, 59, 40))

    await scheduler.tick(now: at(10, 23, 59, 40))
    await scheduler.tick(now: at(10, 23, 59, 50))
    check(scheduler.record.day == "2026-10-10", "still Oct 10 before midnight")

    await scheduler.tick(now: at(11, 0, 0, 0))
    check(scheduler.record.day == "2026-10-11", "rolls over to Oct 11 at local midnight")
    check(scheduler.record.statuses["gym"] == nil, "manual ticks reset on the new day")

    let yesterday = store.loadDay("2026-10-10")
    check(yesterday.accumulatedSeconds["read-pdfs"] == 10, "yesterday's time stays in yesterday's file")
    check(yesterday.statuses["gym"]?.isDone == true, "yesterday's ticks are kept")
    check(scheduler.record.accumulatedSeconds["read-pdfs"] == 10, "the tick that crossed midnight counts toward the new day")

    scheduler.rolloverIfNeeded(now: at(11, 0, 0, 5))
    check(scheduler.record.day == "2026-10-11", "rollover is idempotent within the day")
}

// MARK: - GitHub

group("GitHubEventsClient")
do {
    let http = FakeHTTP([
        .init(status: 200, body: eventsJSON([("PushEvent", "2026-10-10T08:00:00Z")]), etag: "\"abc\""),
        .init(status: 304, body: "", etag: "\"abc\""),
        .init(status: 500, body: "oops", etag: nil),
    ])
    let client = GitHubEventsClient(http: http)
    let t0 = at(10, 12, 0)

    let first = await client.events(for: "octocat", now: t0)
    check(first?.count == 1, "first call fetches and decodes events")
    let firstRequest = await http.requests.first
    check(firstRequest?.url?.absoluteString == "https://api.github.com/users/octocat/events/public?per_page=100", "hits the public events endpoint")
    check(firstRequest?.value(forHTTPHeaderField: "User-Agent") == "Peeko-App", "sends a User-Agent")
    check(firstRequest?.value(forHTTPHeaderField: "If-None-Match") == nil, "no ETag on the first request")

    _ = await client.events(for: "octocat", now: t0.addingTimeInterval(599))
    check(await client.requestCount == 1, "doesn't refetch within 10 minutes")

    let afterNotModified = await client.events(for: "octocat", now: t0.addingTimeInterval(600))
    check(await client.requestCount == 2, "refetches after 10 minutes")
    check(await http.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"", "sends the saved ETag")
    check(afterNotModified == first, "304 keeps the cached events")

    let afterError = await client.events(for: "octocat", now: t0.addingTimeInterval(1200))
    check(afterError == first, "a server error keeps the cached events")

    check(await client.events(for: "../evil", now: t0) == nil, "rejects invalid usernames without a request")
    check(await client.requestCount == 3, "no request was made for the invalid username")
    check(GitHubEventsClient.isValidUsername("a7med-7x7") && !GitHubEventsClient.isValidUsername("-bad"), "username validation")
    check(await client.problem(for: "octocat") == "GitHub answered 500 · trying again soon", "a server error is reported, not hidden")

    let offline = GitHubEventsClient(http: FakeHTTP([]))
    _ = await offline.events(for: "octocat", now: t0)
    check(await offline.problem(for: "OctoCat") == "can't reach GitHub · offline or a firewall?", "a failed request (e.g. a firewall) is reported")
    let missingUser = GitHubEventsClient(http: FakeHTTP([.init(status: 404, body: "", etag: nil), .init(status: 200, body: "[]", etag: nil)]))
    _ = await missingUser.events(for: "nobody", now: t0)
    check(await missingUser.problem(for: "nobody") == "GitHub doesn't know that username", "404 → unknown username")
    _ = await missingUser.events(for: "nobody", now: t0.addingTimeInterval(600))
    check(await missingUser.problem(for: "nobody") == nil, "a good answer clears the problem")

    let tokenHTTP = FakeHTTP([
        .init(status: 200, body: eventsJSON([]), etag: "\"public\""),
        .init(status: 200, body: eventsJSON([("PushEvent", "2026-10-10T09:00:00Z")]), etag: nil),
        .init(status: 401, body: "", etag: nil),
    ])
    let withToken = GitHubEventsClient(http: tokenHTTP)
    _ = await withToken.events(for: "octocat", now: t0)
    await withToken.setToken("  ghp_secret \n")
    let privateEvents = await withToken.events(for: "octocat", now: t0.addingTimeInterval(1))
    check(privateEvents?.count == 1, "setting a token drops the cache and refetches right away")
    let tokenRequest = await tokenHTTP.requests.last
    check(tokenRequest?.url?.absoluteString == "https://api.github.com/users/octocat/events?per_page=100", "a token asks for all events, private ones included")
    check(tokenRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_secret", "sends the trimmed token")
    check(tokenRequest?.value(forHTTPHeaderField: "If-None-Match") == nil, "doesn't reuse the public endpoint's ETag")
    check(await tokenHTTP.requests.first?.value(forHTTPHeaderField: "Authorization") == nil, "no Authorization header without a token")
    _ = await withToken.events(for: "octocat", now: t0.addingTimeInterval(601))
    check(await withToken.problem(for: "octocat") == "GitHub didn't accept your token", "401 → bad token")
    await withToken.setToken("   ")
    check(await withToken.problem(for: "octocat") == nil, "clearing the token clears its problem")
    _ = await withToken.events(for: "octocat", now: t0.addingTimeInterval(602))
    let afterClear = await tokenHTTP.requests.last
    check(afterClear?.url?.path == "/users/octocat/events/public" && afterClear?.value(forHTTPHeaderField: "Authorization") == nil, "a blank token goes back to public events")
}

group("GitHubPushVerifier")
do {
    let push = TaskDefinition(id: "github-push", title: "Push", type: .remoteCheck,
                              params: TaskParams(source: "githubPush", username: ""), icon: "arrow.up.circle")
    func verdict(_ events: [(String, String)], now: Date, username: String = "octocat") async -> TaskStatus {
        let client = GitHubEventsClient(http: FakeHTTP([.init(status: 200, body: eventsJSON(events), etag: nil)]))
        let env = VerifierEnvironment(githubUsername: username, github: client, folders: FolderScanner(store: tempStore()), calendar: calendar)
        return await makeVerifier(for: push, environment: env)!.evaluate(context: .init(now: now, record: DayRecord(day: "x")))
    }

    // 01:00 on Oct 11 in Riyadh (UTC+3) is 22:00 UTC on Oct 10.
    let lateNight = at(11, 2, 0)
    check(await verdict([("PushEvent", "2026-10-10T22:00:00Z")], now: lateNight) == .done(at: at(11, 1, 0)),
          "a push at 01:00 local counts for that local day, though UTC says yesterday")
    check(await verdict([("PushEvent", "2026-10-10T20:00:00Z")], now: lateNight) == .pending,
          "a push from yesterday (local) doesn't count")
    check(await verdict([("WatchEvent", "2026-10-11T05:00:00Z")], now: at(11, 12, 0)) == .pending,
          "only PushEvent counts")
    check(await verdict([("PushEvent", "2026-10-11T09:00:00Z"), ("PushEvent", "2026-10-11T06:00:00Z")], now: at(11, 13, 0)) == .done(at: at(11, 9, 0)),
          "done time is the first push of the day")
    check(await verdict([("PushEvent", "2026-10-11T06:00:00Z")], now: at(11, 13, 0), username: "") == .pending,
          "no username → stays pending")
    check(isVerifiable(push), "githubPush is verifiable")
}

group("Scheduler: completion callback")
do {
    let push = TaskDefinition(id: "github-push", title: "Push", type: .remoteCheck,
                              params: TaskParams(source: "githubPush", username: ""), icon: "arrow.up.circle")
    let http = FakeHTTP([.init(status: 200, body: eventsJSON([("PushEvent", "2026-10-10T06:00:00Z")]), etag: nil)])
    let scheduler = Scheduler(store: tempStore(), frontmost: FakeFrontmost(nil), idle: FakeIdle(5),
                              github: GitHubEventsClient(http: http), calendar: calendar, now: at(10, 12, 0))
    scheduler.tasks = [push, gym]
    scheduler.githubUsername = "octocat"
    var completed: [String] = []
    scheduler.onAutoComplete = { completed.append($0.id) }

    scheduler.setManual(true, for: gym, now: at(10, 12, 0))
    await scheduler.tick(now: at(10, 12, 0))
    await scheduler.tick(now: at(10, 12, 0, 10))
    check(scheduler.record.statuses["github-push"]?.isDone == true, "a push today marks the task done")
    check(completed == ["github-push"], "completion fires once, and never for manual taps")
}

// MARK: - Break reminders

group("BreakTracker")
do {
    func run(_ tracker: inout BreakTracker, from start: Date, seconds: Int, idle: TimeInterval = 5) -> [Date] {
        var due: [Date] = []
        for i in stride(from: 0, through: seconds, by: 10) {
            let now = start.addingTimeInterval(Double(i))
            if tracker.record(sample(now, "com.apple.Safari", idle: idle), interval: 3600) { due.append(now) }
        }
        return due
    }
    let start = at(10, 9, 0)

    var tracker = BreakTracker()
    let due = run(&tracker, from: start, seconds: 2 * 3600)
    check(due == [start.addingTimeInterval(3600), start.addingTimeInterval(7200)], "reminds after each active hour, in any app")

    var idleBreak = BreakTracker()
    _ = run(&idleBreak, from: start, seconds: 50 * 60)
    _ = idleBreak.record(sample(start.addingTimeInterval(50 * 60 + 10), nil, idle: 300), interval: 3600)
    check(idleBreak.activeSeconds == 0, "5 minutes away from the keyboard counts as the break")
    check(run(&idleBreak, from: start.addingTimeInterval(50 * 60 + 20), seconds: 20 * 60).isEmpty, "so 50 + 20 minutes around a break doesn't remind")

    var sleepy = BreakTracker()
    _ = run(&sleepy, from: start, seconds: 50 * 60)
    _ = sleepy.record(sample(start.addingTimeInterval(50 * 60 + 600), "com.apple.Safari", idle: 2), interval: 3600)
    check(sleepy.activeSeconds == 0, "a 10-minute gap between ticks (Mac asleep) counts as a break")

    var reading = BreakTracker()
    let readingDue = run(&reading, from: start, seconds: 3600, idle: 90)
    check(readingDue.count == 1, "reading without touching the mouse for 90s still counts as active")

    var halfIdle = BreakTracker()
    _ = run(&halfIdle, from: start, seconds: 600)
    let before = halfIdle.activeSeconds
    _ = halfIdle.record(sample(start.addingTimeInterval(610), nil, idle: 200), interval: 3600)
    check(halfIdle.activeSeconds == before, "idle between 2 and 5 minutes neither counts nor resets")

    check(BreakMessages.all(minutes: 60).allSatisfy { $0.body.contains("5 minutes") }, "every message asks for 5 minutes")
    check(BreakMessages.duration(minutes: 60) == "an hour" && BreakMessages.duration(minutes: 90) == "90 minutes", "duration wording")
}

// MARK: - Activity windows (sleep, wake)

group("ActivityLog")
do {
    var spans: [ActivitySpan] = []
    let dayStart = at(10, 0, 0)
    check(ActivityLog.note(at(10, 7, 0), in: &spans, notBefore: dayStart), "first input starts a span")
    check(!ActivityLog.note(at(10, 7, 4), in: &spans, notBefore: dayStart), "input within 5 minutes extends it")
    check(spans == [ActivitySpan(start: at(10, 7, 0), end: at(10, 7, 4))], "span covers 07:00–07:04")
    check(ActivityLog.note(at(10, 7, 10), in: &spans, notBefore: dayStart), "a gap over 5 minutes starts a new span")
    var late: [ActivitySpan] = []
    ActivityLog.note(at(9, 23, 59, 50), in: &late, notBefore: dayStart)
    check(late.first?.start == dayStart, "input from before midnight is clamped to the new day")
}

@MainActor func windowTask(_ rule: String, _ from: String, _ until: String) -> TaskDefinition {
    TaskDefinition(id: rule, title: rule, type: .activity, params: TaskParams(rule: rule, from: from, until: until), icon: "moon")
}
@MainActor func judge(_ task: TaskDefinition, spans: [ActivitySpan], now: Date) async -> TaskStatus {
    var record = DayRecord(day: "2026-10-11")
    record.activity = spans
    let env = VerifierEnvironment(githubUsername: "", github: offlineGitHub(), folders: FolderScanner(store: tempStore()), calendar: calendar)
    return await makeVerifier(for: task, environment: env)!.evaluate(context: .init(now: now, record: record))
}

group("Activity window: slept on time (quiet 00:30–05:00)")
do {
    let sleep = windowTask("quietBetween", "00:30", "05:00")
    let evening = [ActivitySpan(start: at(11, 0, 0), end: at(11, 0, 20))]
    check(await judge(sleep, spans: evening, now: at(11, 3, 0)) == .pending, "still pending during the night")
    check(await judge(sleep, spans: evening, now: at(11, 7, 0)) == .done(at: at(11, 5, 0)), "done once 05:00 passes quietly")
    check(await judge(sleep, spans: [], now: at(11, 7, 0)) == .done(at: at(11, 5, 0)), "a Mac that slept all night counts")
    let lateNight = [ActivitySpan(start: at(11, 0, 10), end: at(11, 1, 15))]
    check(await judge(sleep, spans: lateNight, now: at(11, 7, 0)) == .failed, "activity at 01:15 means a late night")
    check(isVerifiable(sleep) && !isVerifiable(windowTask("nope", "00:00", "01:00")), "only known rules are verifiable")
}

group("Activity window: up early (start 04:00–08:00)")
do {
    let wake = windowTask("startBetween", "04:00", "08:00")
    let morning = [ActivitySpan(start: at(11, 0, 5), end: at(11, 0, 40)), ActivitySpan(start: at(11, 7, 12), end: at(11, 9, 0))]
    check(await judge(wake, spans: morning, now: at(11, 9, 0)) == .done(at: at(11, 7, 12)), "first stretch at 07:12 → up early")
    let allNighter = [ActivitySpan(start: at(11, 3, 0), end: at(11, 8, 30))]
    check(await judge(wake, spans: allNighter, now: at(11, 9, 0)) == .failed, "an all-nighter that started at 03:00 isn't an early start")
    check(await judge(wake, spans: [], now: at(11, 6, 0)) == .pending, "pending before 08:00")
    let slow = [ActivitySpan(start: at(11, 9, 30), end: at(11, 10, 0))]
    check(await judge(wake, spans: slow, now: at(11, 10, 0)) == .failed, "first on at 09:30 → a slow morning")
}

group("Scheduler records activity spans")
do {
    let store = tempStore()
    let idle = FakeIdle(3)
    let scheduler = Scheduler(store: store, frontmost: FakeFrontmost(nil), idle: idle, github: offlineGitHub(), calendar: calendar, now: at(10, 7, 0))
    for i in 0..<30 { await scheduler.tick(now: at(10, 7, 0).addingTimeInterval(Double(i) * 10)) }
    idle.seconds = 600
    await scheduler.tick(now: at(10, 7, 10))
    idle.seconds = 2
    await scheduler.tick(now: at(10, 9, 0))
    let spans = scheduler.record.activity ?? []
    check(spans.count == 2, "two stretches with a long idle gap between them")
    check(spans.first?.start == at(10, 7, 0).addingTimeInterval(-3), "a span starts at the last input, not the tick")
    check(store.loadDay("2026-10-10").activity?.count == 2, "spans are saved to the day file")
}

// MARK: - Notes folder

group("FolderScanner and FolderActivityVerifier")
do {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("peeko-vault-\(UUID())")
    try! fm.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    try! fm.createDirectory(at: vault.appendingPathComponent("daily"), withIntermediateDirectories: true)
    var created: [String: Date] = [:]
    func write(_ path: String, words: Int, modified: Date) {
        let url = vault.appendingPathComponent(path)
        try! Array(repeating: "word", count: words).joined(separator: " ").write(to: url, atomically: true, encoding: .utf8)
        if created[path] == nil { created[path] = modified }
        try! fm.setAttributes([.modificationDate: modified, .creationDate: created[path]!], ofItemAtPath: url.path)
    }
    write("old.md", words: 500, modified: at(9, 20, 0))
    write("daily/today.md", words: 100, modified: at(9, 22, 0))
    write(".obsidian/workspace.md", words: 999, modified: at(10, 9, 0))
    write("image.png", words: 50, modified: at(10, 9, 0))

    let store = tempStore()
    let scanner = FolderScanner(store: store)
    let any = TaskDefinition(id: "notes", title: "Notes", type: .folderActivity, params: TaskParams(path: vault.path), icon: "pencil")
    let words = TaskDefinition(id: "words", title: "300 words", type: .folderActivity, params: TaskParams(path: vault.path, minWords: 300), icon: "pencil")
    func status(_ task: TaskDefinition, _ now: Date, scanner: FolderScanner) async -> TaskStatus {
        let env = VerifierEnvironment(githubUsername: "", github: offlineGitHub(), folders: scanner, calendar: calendar)
        return await makeVerifier(for: task, environment: env)!.evaluate(context: .init(now: now, record: DayRecord(day: "2026-10-10")))
    }

    check(await status(any, at(10, 9, 0), scanner: scanner) == .pending, "nothing edited today yet (hidden folders and non-notes ignored)")
    check(await status(words, at(10, 9, 0), scanner: scanner) == .pending, "first scan sets the baseline")

    write("daily/today.md", words: 220, modified: at(10, 9, 30))
    check(await status(any, at(10, 9, 0, 30), scanner: scanner) == .pending, "rescans at most once a minute")
    check(await status(any, at(10, 9, 31), scanner: scanner) == .done(at: at(10, 9, 30)), "any edit today ticks 'write in your notes'")

    let progress = await status(words, at(10, 9, 31), scanner: scanner)
    check(progress == .inProgress(progress: 120.0 / 300.0), "120 words added → 40% of 300")

    write("new-idea.md", words: 200, modified: at(10, 10, 0))
    let restarted = FolderScanner(store: store)
    _ = await status(words, at(10, 10, 1), scanner: restarted)
    check(await status(words, at(10, 10, 5), scanner: restarted) == .done(at: at(10, 10, 5)),
          "after a restart: the saved baseline holds, and a note created today counts in full (120 + 200 ≥ 300)")

    let missing = TaskDefinition(id: "m", title: "m", type: .folderActivity, params: TaskParams(path: "/nope/\(UUID())"), icon: "pencil")
    check(await status(missing, at(10, 10, 0), scanner: scanner) == .pending, "a missing folder stays pending")
    try? fm.removeItem(at: vault)
}

// MARK: - Stay under (appLimit)

group("Stay under: counting and limits")
do {
    let browsers = ["com.apple.Safari", "com.google.Chrome"]
    let youtube = TaskDefinition(id: "youtube", title: "Under 45 min of YouTube", type: .appLimit,
                                 params: TaskParams(bundleIDs: browsers, minutes: 45, titleContains: ["YouTube"]), icon: "play")
    let discord = TaskDefinition(id: "discord", title: "Under 30 min in Discord", type: .appLimit,
                                 params: TaskParams(bundleIDs: ["com.hnc.Discord"], minutes: 30), icon: "bubble")

    var tracker = ActivityTracker()
    var record = DayRecord(day: "2026-10-10")
    let t0 = at(10, 20, 0)
    func tick(_ i: Int, _ app: String?, _ title: String?) {
        tracker.record(ActivitySample(now: t0.addingTimeInterval(Double(i) * 10), frontmostBundleID: app, secondsSinceInput: 5, windowTitle: title),
                       tasks: [youtube, discord], into: &record)
    }
    tick(0, "com.google.Chrome", "Lofi beats - YouTube")
    tick(1, "com.google.Chrome", "Lofi beats - YouTube")
    tick(2, "com.google.Chrome", "Pull requests · GitHub")
    tick(3, "com.apple.Safari", "how to cook rice - youtube")
    tick(4, "com.google.Chrome", nil)
    check(record.accumulatedSeconds["youtube"] == 20, "counts only while a browser shows YouTube (case-insensitive)")
    tick(5, "com.hnc.Discord", nil)
    check(record.accumulatedSeconds["discord"] == 10, "a whole-app limit needs no title")

    let verifier = AppLimitVerifier(definition: youtube)
    var r = DayRecord(day: "2026-10-10")
    r.accumulatedSeconds["youtube"] = 27 * 60
    check(await verifier.evaluate(context: .init(now: t0, record: r)) == .inProgress(progress: 0.6), "27 of 45 min → 60% used")
    r.accumulatedSeconds["youtube"] = 45 * 60
    check(await verifier.evaluate(context: .init(now: t0, record: r)) == .inProgress(progress: 1.0), "exactly at the limit is still okay")
    r.accumulatedSeconds["youtube"] = 45 * 60 + 10
    check(await verifier.evaluate(context: .init(now: t0, record: r)) == .failed, "over the limit → missed for today")
    r.statuses["youtube"] = .failed
    r.accumulatedSeconds["youtube"] = 0
    check(await verifier.evaluate(context: .init(now: t0, record: r)) == .failed, "once over, it stays over for the day")
    check(DayKey.endOfDay("2026-10-10", calendar: calendar) == at(10, 23, 59, 59), "end of day is 23:59:59 local")
}

group("Stay under: scheduler")
do {
    let youtube = TaskDefinition(id: "youtube", title: "YT", type: .appLimit,
                                 params: TaskParams(bundleIDs: ["com.google.Chrome"], minutes: 1, titleContains: ["YouTube"]), icon: "play")
    let discord = TaskDefinition(id: "discord", title: "Discord", type: .appLimit,
                                 params: TaskParams(bundleIDs: ["com.hnc.Discord"], minutes: 30), icon: "bubble")
    let store = tempStore()
    let front = FakeFrontmost("com.google.Chrome", title: "Video - YouTube")
    let scheduler = Scheduler(store: store, frontmost: front, idle: FakeIdle(5), github: offlineGitHub(), calendar: calendar, now: at(10, 22, 0))

    scheduler.tasks = [discord]
    await scheduler.tick(now: at(10, 22, 0))
    check(front.titleRequests == 0, "no window-title lookups when no task needs one")

    scheduler.tasks = [youtube, discord]
    var completed: [String] = []
    scheduler.onAutoComplete = { completed.append($0.id) }
    for i in 1...8 { await scheduler.tick(now: at(10, 22, 0).addingTimeInterval(Double(i) * 10)) }
    check(front.titleRequests == 8, "looks up the title once per tick when needed")
    check(scheduler.record.statuses["youtube"] == .failed, "80s of YouTube is over a 1-minute limit")
    check(scheduler.record.statuses["discord"] == .inProgress(progress: 0), "Discord unused so far")

    await scheduler.tick(now: at(11, 0, 0, 5))
    let yesterday = store.loadDay("2026-10-10")
    check(yesterday.statuses["discord"] == .done(at: at(10, 23, 59, 59)), "stayed under all day → done at the end of the day")
    check(yesterday.statuses["youtube"] == .failed, "went over → stays missed")
    check(completed.isEmpty, "finishing a limit at midnight doesn't send a notification")
}

// MARK: - Catalog v3: windows, gaps, focus, local and online checks

@MainActor func judgeDay(_ task: TaskDefinition, day: Int, spans: [ActivitySpan], now: Date) -> TaskStatus {
    var record = DayRecord(day: DayKey.string(for: at(day, 12, 0), calendar: calendar))
    record.activity = spans
    return ActivityWindowVerifier(definition: task, calendar: calendar).status(record: record, now: now)
}
func span(_ d: Int, _ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int) -> ActivitySpan {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Riyadh")!
    let a = c.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h1, minute: m1))!
    let b = c.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h2, minute: m2))!
    return ActivitySpan(start: a, end: b)
}

group("Stopped working by 11 (quiet 23:00–24:00)")
do {
    let task = TaskDefinition(id: "off11", title: "off", type: .activity,
                              params: TaskParams(rule: "quietBetween", from: "23:00", until: "24:00"), icon: "moon")
    check(ActivityWindowVerifier.minutes("24:00") == 1440 && ActivityWindowVerifier.minutes("24:30") == nil, "24:00 means end of day")
    check(judgeDay(task, day: 10, spans: [span(10, 20, 0, 22, 50)], now: at(10, 23, 30)) == .pending, "pending during the evening")
    check(judgeDay(task, day: 10, spans: [span(10, 20, 0, 22, 50)], now: at(11, 0, 0)) == .done(at: at(11, 0, 0)), "nothing after 23:00 → done at midnight")
    check(judgeDay(task, day: 10, spans: [span(10, 22, 0, 23, 20)], now: at(11, 0, 0)) == .failed, "working at 23:20 → missed")
}

group("Breaks between activity (gapBetween)")
do {
    let lunch = TaskDefinition(id: "lunch", title: "lunch", type: .activity,
                               params: TaskParams(rule: "gapBetween", from: "12:00", until: "15:00", gapMinutes: 30), icon: "fork")
    check(judgeDay(lunch, day: 10, spans: [span(10, 9, 0, 12, 10), span(10, 12, 50, 17, 0)], now: at(10, 18, 0)) == .done(at: at(10, 12, 40)),
          "a 40-min gap from 12:10 → done at 12:40")
    check(judgeDay(lunch, day: 10, spans: [span(10, 9, 0, 12, 10), span(10, 12, 30, 17, 0)], now: at(10, 18, 0)) == .failed,
          "only a 20-min gap → missed after 15:00")
    check(judgeDay(lunch, day: 10, spans: [span(10, 9, 0, 12, 10)], now: at(10, 12, 45)) == .done(at: at(10, 12, 40)),
          "away right now for 35 min already counts")
    check(judgeDay(lunch, day: 10, spans: [span(10, 13, 30, 17, 0)], now: at(10, 18, 0)) == .failed,
          "before your first activity of the day isn't a break")

    let breaks = TaskDefinition(id: "breaks", title: "breaks", type: .activity,
                                params: TaskParams(rule: "gapBetween", from: "09:00", until: "18:00", gapMinutes: 5, count: 4), icon: "walk")
    let day = [span(10, 9, 0, 10, 0), span(10, 10, 10, 11, 0), span(10, 11, 7, 12, 0), span(10, 12, 30, 14, 0), span(10, 14, 6, 17, 0)]
    check(judgeDay(breaks, day: 10, spans: day, now: at(10, 18, 0)) == .done(at: at(10, 14, 5)), "fourth 5-min break at 14:00 → done at 14:05")
    check(judgeDay(breaks, day: 10, spans: Array(day.prefix(3)) + [span(10, 12, 2, 17, 0)], now: at(10, 18, 0)) == .failed,
          "only two real breaks → missed")
}

group("Limits: any app, time windows, zero, focus runs")
do {
    let screen = TaskDefinition(id: "screen", title: "screen", type: .appLimit,
                                params: TaskParams(bundleIDs: [], minutes: 480), icon: "display")
    let social = TaskDefinition(id: "social", title: "social", type: .appLimit,
                                params: TaskParams(bundleIDs: ["com.google.Chrome"], minutes: 0, titleContains: ["Reddit"], from: "00:00", until: "12:00"), icon: "hand")
    let focus = TaskDefinition(id: "focus", title: "focus", type: .appTime,
                               params: TaskParams(bundleIDs: ["com.microsoft.VSCode"], minutes: 50, continuous: true), icon: "scope")
    var tracker = ActivityTracker(calendar: calendar)
    var record = DayRecord(day: "2026-10-10")
    var now = at(10, 11, 58)
    func tick(_ app: String, _ title: String? = nil) {
        now = now.addingTimeInterval(10)
        tracker.record(ActivitySample(now: now, frontmostBundleID: app, secondsSinceInput: 3, windowTitle: title),
                       tasks: [screen, social, focus], into: &record)
    }
    tracker.record(ActivitySample(now: now, frontmostBundleID: "com.apple.Notes", secondsSinceInput: 3), tasks: [screen, social, focus], into: &record)
    tick("com.apple.Notes")
    check(record.accumulatedSeconds["screen"] == 10, "an empty app list counts any app")
    check(AppLimitVerifier(definition: social).status(record: record) == .inProgress(progress: 0), "zero limit, nothing yet → still fine")
    for _ in 0..<10 { tick("com.google.Chrome", "r/swift - Reddit") }   // 11:58:20 … 11:59:50
    check(record.accumulatedSeconds["social"] == 100, "Reddit before noon counts toward a zero limit")
    check(AppLimitVerifier(definition: social).status(record: record) == .failed, "any time over a zero limit → missed")
    tick("com.google.Chrome", "r/swift - Reddit")
    check(record.accumulatedSeconds["social"] == 100, "at 12:00 the window is closed")

    for _ in 0..<30 { tick("com.microsoft.VSCode") }
    check(record.accumulatedSeconds["focus"] == 300, "5 minutes straight in VS Code")
    for _ in 0..<3 { tick("com.tinyspeck.slackmacgap") }
    for _ in 0..<6 { tick("com.microsoft.VSCode") }
    check(record.accumulatedSeconds["focus"] == 360, "a 30-second look at Slack doesn't break the run")
    for _ in 0..<9 { tick("com.tinyspeck.slackmacgap") }
    for _ in 0..<12 { tick("com.microsoft.VSCode") }
    check(record.accumulatedSeconds["focus"] == 360, "90 seconds away starts a new run; the best run stays 6 min")
}

group("Finalizing the day at rollover")
do {
    let off11 = TaskDefinition(id: "off11", title: "off", type: .activity,
                               params: TaskParams(rule: "quietBetween", from: "23:00", until: "24:00"), icon: "moon")
    let screen = TaskDefinition(id: "screen", title: "screen", type: .appLimit, params: TaskParams(bundleIDs: [], minutes: 480), icon: "display")
    let store = tempStore()
    let idle = FakeIdle(3)
    let scheduler = Scheduler(store: store, frontmost: FakeFrontmost("com.apple.Notes"), idle: idle, github: offlineGitHub(), calendar: calendar, now: at(10, 22, 0))
    scheduler.tasks = [off11, screen]
    await scheduler.tick(now: at(10, 22, 0))
    idle.seconds = 4000
    await scheduler.tick(now: at(11, 7, 0))
    let yesterday = store.loadDay("2026-10-10")
    check(yesterday.statuses["off11"] == .done(at: at(11, 0, 0)), "Mac slept at 22:00 → 'stopped by 11' settles as done at rollover")
    check(yesterday.statuses["screen"] == .done(at: at(10, 23, 59, 59)), "screen time under 8 h → done for the day")
}

group("Local checks: daily note, tidy folder, Time Machine, git, Reminders")
do {
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("peeko-daily-\(UUID())")
    try! fm.createDirectory(at: vault.appendingPathComponent("Daily"), withIntermediateDirectories: true)
    let note = TaskDefinition(id: "daily", title: "daily", type: .folderActivity, params: TaskParams(path: vault.path, dailyNote: true), icon: "note")
    let env = VerifierEnvironment(githubUsername: "", github: offlineGitHub(), folders: FolderScanner(store: tempStore()), calendar: calendar)
    check(await makeVerifier(for: note, environment: env)!.evaluate(context: .init(now: at(10, 9, 0), record: DayRecord(day: "2026-10-10"))) == .pending,
          "no note for today yet")
    let url = vault.appendingPathComponent("Daily/2026-10-10.md")
    try! "today".write(to: url, atomically: true, encoding: .utf8)
    try! fm.setAttributes([.modificationDate: at(10, 8, 30)], ofItemAtPath: url.path)
    let env2 = VerifierEnvironment(githubUsername: "", github: offlineGitHub(), folders: FolderScanner(store: tempStore()), calendar: calendar)
    check(await makeVerifier(for: note, environment: env2)!.evaluate(context: .init(now: at(10, 9, 5), record: DayRecord(day: "2026-10-10"))) == .done(at: at(10, 8, 30)),
          "Daily/2026-10-10.md exists → done")

    for i in 0..<3 { try! "x".write(to: vault.appendingPathComponent("file\(i).txt"), atomically: true, encoding: .utf8) }
    try! "hidden".write(to: vault.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
    check(FolderTidyVerifier.itemCount(vault.path) == 4, "counts visible items only: Daily/ + 3 files, not .DS_Store")
    let tidy = TaskDefinition(id: "tidy", title: "tidy", type: .folderTidy, params: TaskParams(from: "17:00", path: vault.path, maxItems: 4), icon: "sparkles")
    let tidyVerifier = FolderTidyVerifier(definition: tidy, calendar: calendar)
    check(await tidyVerifier.evaluate(context: .init(now: at(10, 12, 0), record: DayRecord(day: "2026-10-10"))) == .pending, "before 17:00 it doesn't count yet")
    check(await tidyVerifier.evaluate(context: .init(now: at(10, 17, 30), record: DayRecord(day: "2026-10-10"))) == .done(at: at(10, 17, 30)), "4 items ≤ 4 after 17:00 → done")
    try? fm.removeItem(at: vault)

    let plist: [String: Any] = ["Destinations": [["SnapshotDates": [at(9, 22, 0), at(10, 3, 15)]], ["SnapshotDates": [at(8, 1, 0)]]]]
    check(BackupVerifier.latestBackup(plist: plist) == at(10, 3, 15), "latest backup across destinations")

    check(RemindersDay(completedToday: [at(10, 9, 0), at(10, 11, 0)], openDueToday: 0).status == .done(at: at(10, 11, 0)), "all due today done → cleared at the last one")
    check(RemindersDay(completedToday: [at(10, 9, 0)], openDueToday: 1).status == .pending, "one still open → not yet")
    check(RemindersDay(completedToday: [], openDueToday: 0).status == .pending, "nothing done at all doesn't count as cleared")

    if let git = GitScanner.git {
        let repo = fm.temporaryDirectory.appendingPathComponent("peeko-git-\(UUID())/proj")
        try! fm.createDirectory(at: repo, withIntermediateDirectories: true)
        func g(_ args: String...) { _ = GitScanner.run(git, ["-C", repo.path] + args) }
        g("init", "-q")
        try! "hi".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        g("add", ".")
        g("-c", "user.name=Test", "-c", "user.email=me@example.com", "commit", "-q", "-m", "first")
        let root = repo.deletingLastPathComponent().path
        let scanner = GitScanner()
        let mine = await scanner.firstCommitToday(root: root, author: "me@example.com", now: .now, calendar: .current)
        check(mine != nil && Calendar.current.isDateInToday(mine!), "finds today's commit in a repo one level down")
        let theirs = await GitScanner().firstCommitToday(root: root, author: "someone@else.com", now: .now, calendar: .current)
        check(theirs == nil, "ignores commits by other authors")
        try? fm.removeItem(atPath: root)
    } else {
        print("  - git not installed; skipping the git check")
    }
}

group("Online checks: feeds and Duolingo")
do {
    let rss = """
    <?xml version="1.0"?><rss version="2.0"><channel><title>Blog</title><pubDate>Sat, 10 Oct 2026 20:00:00 +0300</pubDate>
    <item><title>Old</title><pubDate>Thu, 08 Oct 2026 10:00:00 +0300</pubDate></item>
    <item><title>New</title><pubDate>Sat, 10 Oct 2026 09:30:00 +0300</pubDate></item>
    </channel></rss>
    """
    check(FeedDates.parse(Data(rss.utf8)).count == 2, "reads item dates, not the channel's own date")
    let atom = """
    <feed xmlns="http://www.w3.org/2005/Atom"><updated>2026-10-10T12:00:00Z</updated>
    <entry><title>Post</title><published>2026-10-10T06:15:00Z</published><updated>2026-10-10T07:00:00Z</updated></entry></feed>
    """
    check(FeedDates.parse(Data(atom.utf8)).min() == at(10, 9, 15), "Atom published date (06:15Z = 09:15 in UTC+3)")

    let feedTask = TaskDefinition(id: "blog", title: "blog", type: .remoteCheck, params: TaskParams(source: "feed", url: "https://example.com/feed.xml"), icon: "rss")
    let feedEnv = VerifierEnvironment(githubUsername: "", github: offlineGitHub(), folders: FolderScanner(store: tempStore()), calendar: calendar,
                                      fetcher: CachedFetcher(http: FakeHTTP([.init(status: 200, body: rss, etag: nil)])))
    check(await makeVerifier(for: feedTask, environment: feedEnv)!.evaluate(context: .init(now: at(10, 21, 0), record: DayRecord(day: "2026-10-10"))) == .done(at: at(10, 9, 30)),
          "a post dated today → published")
    check(FeedVerifier.url("ftp://nope") == nil && FeedVerifier.url("https://a.b/rss") != nil, "only http(s) feed URLs")

    let duo = #"{"users":[{"streak":3971,"streakData":{"currentStreak":{"length":3971,"startDate":"2019-07-25","endDate":"2026-10-10"}}}]}"#
    check(DuolingoVerifier.streakEndDate(Data(duo.utf8)) == "2026-10-10", "reads the streak's end date")
    let duoTask = TaskDefinition(id: "duo", title: "duo", type: .remoteCheck, params: TaskParams(source: "duolingo", username: "luis"), icon: "duo")
    let duoEnv = VerifierEnvironment(githubUsername: "", github: offlineGitHub(), folders: FolderScanner(store: tempStore()), calendar: calendar,
                                     fetcher: CachedFetcher(http: FakeHTTP([.init(status: 200, body: duo, etag: nil)])))
    check(await makeVerifier(for: duoTask, environment: duoEnv)!.evaluate(context: .init(now: at(10, 20, 0), record: DayRecord(day: "2026-10-10"))) == .done(at: at(10, 20, 0)),
          "streak ends today → lesson done")
    check(DuolingoVerifier.url(for: "bad name!") == nil, "rejects odd usernames")
}

group("Online checks: LeetCode and Codeforces")
do {
    // 06:15 UTC on Oct 10 = 09:15 in UTC+3; 1791648000 = Oct 10 ~16:00 UTC; 1791500000 = Oct 9.
    let t1 = at(10, 9, 15).timeIntervalSince1970
    let lc = #"{"data":{"recentAcSubmissionList":[{"title":"Two Sum","timestamp":"\#(Int(t1))"},{"title":"Old","timestamp":"1791500000"}]}}"#
    check(LeetCodeVerifier.acceptedTimes(Data(lc.utf8)).count == 2, "reads LeetCode's accepted timestamps")
    let lcHTTP = FakeHTTP([.init(status: 200, body: lc, etag: nil)])
    let lcTask = TaskDefinition(id: "lc", title: "lc", type: .remoteCheck, params: TaskParams(source: "leetcode", username: "lee215"), icon: "lc")
    let lcEnv = VerifierEnvironment(githubUsername: "", github: offlineGitHub(), folders: FolderScanner(store: tempStore()), calendar: calendar,
                                    fetcher: CachedFetcher(http: lcHTTP))
    check(await makeVerifier(for: lcTask, environment: lcEnv)!.evaluate(context: .init(now: at(10, 20, 0), record: DayRecord(day: "2026-10-10"))) == .done(at: at(10, 9, 15)),
          "an accepted solution today → solved")
    let sent = await lcHTTP.requests.first
    check(sent?.httpMethod == "POST" && String(decoding: sent?.httpBody ?? Data(), as: UTF8.self).contains("lee215"),
          "asks LeetCode's GraphQL with a POST carrying the username")

    let cf = #"{"status":"OK","result":[{"creationTimeSeconds":\#(Int(t1)),"verdict":"WRONG_ANSWER","problem":{"name":"A"}},{"creationTimeSeconds":\#(Int(t1) + 600),"verdict":"OK","problem":{"name":"A"}}]}"#
    check(CodeforcesVerifier.acceptedTimes(Data(cf.utf8)) == [at(10, 9, 25)], "only OK verdicts count")
    let cfTask = TaskDefinition(id: "cf", title: "cf", type: .remoteCheck, params: TaskParams(source: "codeforces", username: "tourist"), icon: "cf")
    let cfEnv = VerifierEnvironment(githubUsername: "", github: offlineGitHub(), folders: FolderScanner(store: tempStore()), calendar: calendar,
                                    fetcher: CachedFetcher(http: FakeHTTP([.init(status: 200, body: cf, etag: nil)])))
    check(await makeVerifier(for: cfTask, environment: cfEnv)!.evaluate(context: .init(now: at(10, 20, 0), record: DayRecord(day: "2026-10-10"))) == .done(at: at(10, 9, 25)),
          "a wrong answer then an accepted one → solved at the accepted time")
    check(CodeforcesVerifier.request(for: "bad handle") == nil && LeetCodeVerifier.request(for: "") == nil, "rejects odd handles")

    let offline = CachedFetcher(http: FakeHTTP([]))
    let request = LeetCodeVerifier.request(for: "lee215")!
    _ = await offline.body(for: request, every: 600, now: at(10, 9, 0))
    check(await offline.problem(for: request) == "can't reach leetcode.com · offline or a firewall?", "an unreachable site is reported")
}

// MARK: - History and streaks

group("History and streaks")
do {
    let store = tempStore()
    func day(_ d: Int, done ids: [String], pending: [String] = []) {
        var record = DayRecord(day: DayKey.string(for: at(d, 12, 0), calendar: calendar))
        for id in ids { record.statuses[id] = .done(at: at(d, 12, 0)) }
        for id in pending { record.statuses[id] = .pending }
        try! store.save(record)
    }
    day(4, done: ["gym"])
    // Oct 5 missing entirely: breaks streaks
    day(6, done: ["gym", "water"])
    day(7, done: ["gym"])
    day(8, done: ["water"], pending: ["gym"])
    day(9, done: ["gym", "water"])
    day(10, done: [], pending: ["gym"])

    let today = at(10, 15, 0)
    let history = History.load(from: store, days: 30, endingAt: today, calendar: calendar)
    check(history.overallStreak(today: today) == 4, "today with nothing done yet doesn't break the 4-day streak (Oct 6–9)")
    check(history.streak(for: "gym", today: today) == 1, "gym: done Oct 9, missed Oct 8 → 1")
    check(history.streak(for: "water", today: today) == 2, "water: Oct 8 and 9 → 2")
    check(history.timesDone("gym", inLast: 30, today: today) == 4, "gym done 4 times in the last 30 days")
    check(history.doneCount(on: at(6, 9, 0)) == 2, "two things done on Oct 6")

    var live = history
    var todayRecord = store.loadDay("2026-10-10")
    todayRecord.statuses["gym"] = .done(at: today)
    live.replace(todayRecord)
    check(live.overallStreak(today: today) == 5, "finishing something today extends the streak to 5")
    check(live.streak(for: "gym", today: today) == 2, "and gym's streak to 2")

    check(store.allDayKeys() == ["2026-10-04", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09", "2026-10-10"], "lists saved days, oldest first")
    let export = PeekoExport.make(from: store, now: today)
    let decoded = try! JSONDecoder.iso8601.decode(PeekoExport.self, from: export.encoded())
    check(decoded.days.count == 6 && decoded.days.first?.day == "2026-10-04", "export includes every day")
}

// MARK: - Settings and the evening nudge

group("AppSettings and EveningNudge")
do {
    let legacy = try! JSONDecoder().decode(AppSettings.self, from: Data(#"{"schemaVersion":1,"githubUsername":"octocat"}"#.utf8))
    check(legacy.breakRemindersEnabled && legacy.breakIntervalMinutes == 60, "break reminders default to on, every 60 minutes")
    check(legacy.githubUsername == "octocat" && legacy.eveningNudgeEnabled && legacy.eveningNudgeMinutes == 21 * 60,
          "missing fields fall back to defaults")

    let store = tempStore()
    var settings = AppSettings()
    settings.hasCompletedOnboarding = true
    try! store.save(settings)
    check(store.loadSettings() == settings, "settings round-trip")

    let s = AppSettings()
    check(!EveningNudge.isDue(now: at(10, 20, 59), settings: s, lastNudgeDay: nil, remaining: 2, calendar: calendar), "not before 21:00")
    check(EveningNudge.isDue(now: at(10, 21, 0), settings: s, lastNudgeDay: nil, remaining: 2, calendar: calendar), "due at 21:00 with tasks left")
    check(!EveningNudge.isDue(now: at(10, 22, 0), settings: s, lastNudgeDay: "2026-10-10", remaining: 2, calendar: calendar), "only once per day")
    check(!EveningNudge.isDue(now: at(10, 21, 30), settings: s, lastNudgeDay: nil, remaining: 0, calendar: calendar), "not when everything's done")
    var off = AppSettings(); off.eveningNudgeEnabled = false
    check(!EveningNudge.isDue(now: at(10, 21, 30), settings: off, lastNudgeDay: nil, remaining: 2, calendar: calendar), "not when turned off")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
