# Architecture

Peeko is a SwiftPM package with three targets:

| Target | Kind | Contains |
|---|---|---|
| `PeekoCore` | library, no SwiftUI | models, verifiers, persistence, the scheduler, and platform providers |
| `PeekoApp` | executable | the `MenuBarExtra` UI, the app model, and the menu bar icon |
| `PeekoChecks` | executable (`Checks/`) | logic checks with fake providers, run by `make check` |

Keeping the logic in `PeekoCore` means it can be tested without the UI or a real Mac session.

## Tasks are data

Every task is **one verifier type plus parameters**:

```json
{
  "id": "read-pdfs",
  "title": "Read for 30 minutes",
  "type": "appTime",
  "params": { "bundleIDs": ["com.apple.Preview"], "minutes": 30, "idleCutoffSeconds": 120 },
  "icon": "book"
}
```

| Type | Meaning | Status |
|---|---|---|
| `manual` | You tick it | done |
| `appTime` | Adds up active minutes while one of the given apps is in front | done |
| `remoteCheck` | Polls an outside source: `githubPush`, `feed` (RSS/Atom item dated today), `duolingo` (streak ends today), `leetcode` (accepted submission today, GraphQL POST), `codeforces` (verdict `OK` today, official API) | done |
| `activity` | Judges a time window against today's activity stretches (`quietBetween`, `startBetween`) | done |
| `folderActivity` | Watches a notes folder: any edit today, or `minWords` added today | done |
| `appLimit` | Stay under N active minutes in an app, any app if `bundleIDs` is empty, optionally only while the window title matches and only inside a `from`–`until` window (a 0-minute limit means "none") | done |
| `gitCommits` | A commit today by `author` in any git repo under `path` (two levels deep), via `git log` | done |
| `backup` | Time Machine's latest `SnapshotDates` entry is today | done |
| `reminders` | Something completed today and nothing due today left open (EventKit) | done |
| `folderTidy` | At most `maxItems` visible items in `path` (Desktop) after `from` | done |

Built-in presets live in `Resources/catalog.json`. Custom tasks use the same shape, with ids that start with `custom-`.

- **Adding a preset** means editing JSON. No Swift needed.
- **Adding a type** means writing one struct that conforms to `Verifier` and registering it in `makeVerifier(for:)`.

Don't hardcode a particular app or task in Swift. Make it a preset of a generic type.

### Verifiers

```swift
protocol Verifier: Sendable {
    var definition: TaskDefinition { get }
    func evaluate(context: VerifierContext) async -> TaskStatus
}

enum TaskStatus { case pending, inProgress(progress: Double), done(at: Date), failed }
```

`ManualVerifier` just returns whatever the day record says. `AppTimeVerifier` turns accumulated seconds into `pending`, `inProgress(seconds / target)`, or `done`. Once done, it keeps the original completion time.

## Scheduler and app time

`Scheduler` (`@MainActor @Observable`) owns **today's `DayRecord`**. Every 10 seconds it:

1. rolls over to a new day file if the local date changed
2. asks the providers which app is in front (`FrontmostAppProvider`) and how long since the last input (`IdleTimeProvider`)
3. passes that sample to `ActivityTracker`, which credits time to matching `appTime` tasks
4. evaluates the automatic tasks' verifiers and saves if anything changed

`ActivityTracker` is a pure struct, so its rules are easy to check:

- Credit is `min(now - lastTick, 10s)`. A sleeping Mac never adds hours, and a clock that jumps backwards adds nothing.
- The first tick, and the first tick after `pause()`, only start the clock.
- A tick counts only if the front app is one of the task's `bundleIDs` and the time since your last input is within `idleCutoffSeconds` (120s by default).

`willSleep` and `screensDidSleep` call `pause()`. The providers are `@MainActor` protocols. The real ones use `NSWorkspace.frontmostApplication` and `CGEventSource.secondsSinceLastEventType`; neither needs a permission. `Checks/` swaps in fakes.

Manual tasks are never written by evaluation. Their status comes only from taps (`setManual`), so a tick that's partway through an `await` can't undo one.

## GitHub push check

`GitHubPushVerifier` passes when the user's public events include a `PushEvent` whose `created_at` (UTC) falls on **today in the user's calendar**. The done time is the day's first push. The username comes from the task's own `params.username`, or from `AppSettings.githubUsername` if that's empty.

`GitHubEventsClient` is an actor shared through `VerifierEnvironment`. The verifier is evaluated every 10s tick, but the client:

- fetches at most once per user every 10 minutes and serves the cache in between
- sends the last `ETag` as `If-None-Match`; a 304 keeps the cache
- keeps the cache on errors and retries at the next poll
- validates usernames before building a URL
- uses `URLSessionHTTPClient` with no `URLCache`, so the 304s reach us
- with a token (`setToken`), asks `/users/{name}/events` with `Authorization: Bearer` instead of `/events/public`; authenticated as that user, GitHub includes their private events. Changing the token drops the cache, and a 401 shows as "GitHub didn't accept your token"

The token is optional and lives in the login Keychain (`Keychain.swift`, service `com.a7med7x7.peeko`, account `github-token`), never in `settings.json`. `AppModel` reads it at launch and hands it to the scheduler; Settings only shows whether one is saved. A classic token with the `repo` scope works. The app is ad-hoc signed, so after an update macOS may ask once to let Peeko read it.

Unauthenticated 304s **do** count against GitHub's 60/hour limit; polling every 10 minutes uses 6. GitHub's events API can lag by hours, so the UI says "checking…" rather than "not done".

`makeVerifier(for:environment:)` builds verifiers. `VerifierEnvironment` carries the GitHub client, the username, and the calendar. `isVerifiable(_:)` answers "is there a verifier for this?" without building one.

## Activity stretches, sleep and early mornings

Every tick where the last input was within 2 minutes, the scheduler passes the moment of that input (`now - secondsSinceInput`) to `ActivityLog.note`. That extends today's last span, or starts a new one after a gap of more than 5 minutes. Input from before midnight is clamped to the new day. Spans live in `DayRecord.activity`. A new span saves right away; extending one saves at most once a minute.

`ActivityWindowVerifier` reads those spans:

- `quietBetween` (Slept on time, 00:30–05:00): `failed` if any span overlaps the window. Otherwise `pending` until `until`, then `done(at: until)`. A Mac that slept all night passes.
- `startBetween` (Up before 8, 04:00–08:00): done at the start of the first span that *starts* at or after `from`, if that's before `until`. So an all-nighter that began at 03:00 doesn't count. It's `failed` once `until` passes without one.

`failed` is shown gently ("up late last night · no worries"). It counts as settled, not left, for the evening reminder and the overall mood. Peeko only sees the Mac, and only while it's running.

## More rules worth knowing

- **Gaps (`gapBetween`)**: breaks are gaps between activity spans inside the window, of at least `gapMinutes`, `count` times. Time before the day's first activity isn't a break; a gap still in progress counts.
- **Continuous runs (`appTime` + `continuous`)**: `ActivityTracker` keeps a per-task run in memory. Matching ticks extend it; once you've been away longer than `runGrace` (60s) it resets. Sleep (`pause()`) ends it. `accumulatedSeconds` holds the *best* run, so `AppTimeVerifier` works unchanged.
- **Day settling**: on rollover, `Scheduler.finalizeDay()` evaluates `activity` tasks with `now` = the end of that day (so "stopped by 11" settles even if the Mac slept), and marks limits still under their cap as done.
- **Copy lives in data**: `params.doneNote` / `missedNote` (with `{time}`) let a preset speak in its own words. `TaskDetail` falls back to generic lines.
- **Shared caches**: `CachedFetcher` (feeds, Duolingo, LeetCode, Codeforces; GET or POST, keyed by URL + body; ETag / Last-Modified, per-request interval and problem text, surfaced in the Today row via `onlineRequest(for:)`), `GitScanner` (5-minute cache, never calls `/usr/bin/git`, which would pop the developer-tools installer) and `RemindersReader` live on the `Scheduler` for its lifetime and reach verifiers through `VerifierEnvironment`.
- **Setup on switch-on**: `AppModel.setup(for:)` says what a preset needs (a folder, a feed link, a username); `PresetToggle` asks with `PickedFolder` / `AskText`, Reminders asks for EventKit access, and title-filtered limits ask for Accessibility. Presets that no longer ship stay removable under "Your tasks".

## Notes folder

`FolderActivityVerifier` asks the shared `FolderScanner` actor, which rescans a folder at most once a minute. It skips hidden folders (`.obsidian`, `.git`, `.trash`), packages, files over 5 MB, and extensions other than `md` / `markdown` / `txt`.

- With `minWords` at 0, any file modified today passes, at the earliest modification time.
- With `minWords` set, words added today = for each file changed today, its words now minus its words at the start of the day:
  - "Start of the day" is the first scan after launch or midnight.
  - Files created today start at 0, even if they were created before the first scan.
  - Once a file changes, its starting count is saved in `words/<day>.json`, so a restart keeps it.
  - Words are whitespace-separated tokens, which works for any script.

The folder comes from an `NSOpenPanel` when the preset is switched on, and is stored in the enabled task's `params.path`. If the folder is in a protected location (Documents, Desktop, iCloud Drive), macOS may ask once for access. Sync tools that touch file dates can trigger the "any edit" mode.

## Stay-under limits (`appLimit`)

Time is counted by the same `ActivityTracker` as `appTime`. A task with `titleContains` only counts while the front window's title contains one of the strings (case-insensitive). The scheduler only asks `FrontmostAppProvider.frontmostWindowTitle()` when some enabled task needs it. The real provider reads `kAXFocusedWindowAttribute` → `kAXTitleAttribute` through the Accessibility API, with a 0.25s messaging timeout, and returns nil without permission.

`AppLimitVerifier` returns `inProgress(used / limit)` while at or under the limit, and `failed` once over. Once failed it stays failed for the day. Being under the limit isn't "done" during the day: on rollover, `Scheduler.finalizeLimits()` marks still-under limits `done(at: 23:59:59)` in yesterday's file, so they count in History without a notification. Limits never count as "left" for the evening reminder or the overall mood.

Accessibility is requested (`AXIsProcessTrustedWithOptions` with the prompt option) only when a title-filtered preset is turned on, or from Settings. Ad-hoc signed builds get a new code identity each release, so macOS may ask to re-allow it after updating.

## History and streaks

`History` (core) holds a window of `DayRecord`s, `History.load(from:days:endingAt:)` reading the last 35 day files. The app swaps in the live record for today (`replace`).

- **Overall streak:** consecutive days with at least one task done.
- **Per-task streak:** consecutive days that task was done.
- **Today** only extends a streak; it never breaks one before the day is over. Counting starts from yesterday if nothing is done yet today.
- A missing day file counts as an empty day, so it breaks the streak.

`AppModel` reloads past days once per local day (at launch and on rollover), so opening the History tab is cheap. `PeekoExport` bundles `tasks.json`, `settings.json` and every day file (`Store.allDayKeys()`) into one JSON document for Settings → Export.

## Persistence

`Store` reads and writes JSON in `~/Library/Application Support/Peeko/`:

- `tasks.json` (`TaskList`): the enabled tasks, in display order
- `settings.json` (`AppSettings`): GitHub username, evening reminder, onboarding done. Every field decodes with a default, so older files keep loading.
- `days/yyyy-MM-dd.json` (`DayRecord`): `statuses` and `accumulatedSeconds` keyed by task id, plus `activity` spans
- `words/yyyy-MM-dd.json` (`WordBaselines`): per-file starting word counts for the notes-folder tasks

Rules:

- Every file has a `schemaVersion`. Schema changes are **additive only**, so older files keep decoding.
- Writes are atomic. A file that fails to decode is moved aside, never overwritten.
- One file per day makes history, streaks and export simple later on.

## Days and time zones

The day key comes from `DayKey.string(for:)`, which uses `Calendar.current`: local time, never UTC. At 01:00 in UTC+3 it's already the new day, even though UTC says yesterday.

The scheduler moves to a new day file on every tick, on `NSCalendarDayChanged`, and whenever the popover opens. Yesterday's file is already saved, so a rollover just loads (or creates) today's. A tick that crosses midnight credits its few seconds to the new day.

## App layer

- **`AppModel`** (`@MainActor @Observable`) holds the presets, the task list (`tasks.json`) and the settings (`settings.json`), and owns the `Scheduler`. Whenever the task list or GitHub username changes, it updates the scheduler and asks it to re-evaluate. It also owns notification permission, launch at login (`SMAppService.mainApp`) and the `Updater` (Sparkle; see [releasing.md](releasing.md#auto-updates-sparkle)).
- **Notifications** (`Notifier`, wrapping `UNUserNotificationCenter`):
  - `Scheduler.onAutoComplete` fires once when an *automatic* task flips to done, and the app posts "Peeko saw that!". Manual taps never notify.
  - `Scheduler.onTick` drives the evening reminder. `EveningNudge.isDue` decides, and the last reminder's day is kept in `UserDefaults` so it fires at most once a day.
  - Break reminders also run from `onTick`. `BreakTracker`, a pure struct in the core, adds up active screen time in any app: input within 2 minutes counts, using the same capped 10-second ticks. Five or more minutes idle, or a 5+ minute gap between ticks (asleep, app not running), counts as the break and resets the count. Each reminder also restarts it. The messages rotate (`BreakMessages`). The interval and on/off live in `AppSettings`.
  - Banners show even while the popover is open.
- **Onboarding** replaces the tabs on first launch, until `hasCompletedOnboarding`: welcome, then the notification permission (with a reason), then an optional GitHub username. The tab bar stays in the layout, invisible, so the panel height doesn't change.
- **`RootView`** draws the header (face, wordmark, `done / total`, streak), the Today / Explore / History / Settings tabs, and the footer. The content area has a **fixed height**: a `MenuBarExtra` window that resizes when you switch tabs drifts away from the menu bar.
- **`MainWindowView`** is a second scene (`Window(id: "main")`, hidden title bar), opened from the popover footer with `openWindow`. It shows a sidebar (face, the four sections with ⌘1–4, today's count and streak) and the same `TodayView` / `CatalogView` / `HistoryView(weeks: 20)` / `SettingsView` in a wider scroll column, except Explore, which uses `CatalogGridView`: a search field (⌘F, matching title, description and category), `TaskCategory` chips derived from the verifier type (each group has a color in `Theme`, used on icons and chips only, never on status), and an adaptive `LazyVGrid` of cards. The popover keeps the compact `CatalogView` list. Both share `PresetToggle` (including the folder picker for writing presets), `DeleteTaskButton` and `ManualTaskForm`. Its `onAppear` switches the activation policy to `.regular` (Dock icon, ⌘Tab), and `onDisappear` switches back to `.accessory`. `LSUIElement` keeps it menu-bar-only at launch; the window isn't opened automatically.
- **`FaceView`** draws Peeko from the brand file's 72×60 geometry. Status maps to a face: pending or failed → *dozing*, in progress → *looking*, done → *beaming*.
- **`MenuBarIcon`** draws an eyes-only **template** `NSImage`, so macOS tints it for light and dark menu bars. It shows the day's overall mood: nothing done → dozing, some progress → looking, everything done → beaming.

## The bundle

`scripts/bundle.sh` builds the `.app` without Xcode:

```
Peeko.app/Contents/
├── Info.plist      # com.a7med7x7.peeko, LSUIElement=true, LSMinimumSystemVersion=14.0
├── MacOS/Peeko
└── Resources/catalog.json
```

Later phases add `AppIcon.icns`, a DMG, a Developer ID signature and notarization, and Sparkle updates. See [blueprint.md](blueprint.md) §6.
