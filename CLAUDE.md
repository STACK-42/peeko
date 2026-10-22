# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Peeko is a local-first macOS menu bar app (Swift 6, SwiftUI, SwiftPM, **no Xcode**) that keeps a daily task list and ticks tasks off from signals on the Mac. A Windows companion (C# / .NET 8, WinForms) lives in `windows/`; it is a sibling of the macOS app, not a replacement or a rewrite of it.

## Where things are documented

- [docs/blueprint.md](docs/blueprint.md): product spec and the phased build plan (§8). It's the source of truth. Each phase has **Do / Done when / Do not touch** lists; follow them and don't pull later phases forward.
- [docs/architecture.md](docs/architecture.md): targets, verifier model, persistence, day rollover, and the app layer.
- [docs/development.md](docs/development.md): environment, commands, data folder, and toolchain quirks.
- [docs/releasing.md](docs/releasing.md): icon, DMG, versioning, the tag-driven release workflow, and signing.
- [docs/brand/Peeko Brand.dc.html](<docs/brand/Peeko Brand.dc.html>): character, colors, and the three status faces.
- `site/` is the website at https://peeko.stack42.tech (GitHub Pages via `.github/workflows/pages.yml`, which copies in `install.sh` and `docs/assets/` images). Preview with `make site` (port 8642). It mirrors the app's look; keep its copy and the README in sync.
- `README.md` is public-facing. Keep it short, plain and human. Put dev details in `docs/`, not the README.
- [windows/README.md](windows/README.md): the Windows port: layout, how to run it, scope. It isn't in the blueprint's phase plan yet, so check with the user before treating it as a phase.

**Status:** v0.2.0 released; `main` also has appLimit ("stay under" tasks), LeetCode and Codeforces checks, the full window, and launch at login on by default (see `CHANGELOG.md` Unreleased). Next on the roadmap: Sparkle auto-updates and an optional GitHub token for private repos; see the blueprint (§9).

**Windows status:** an early port (`windows/`, v1, "build 13"; released under the tag `windows-v1`, never a `v*` tag). It runs every task type except `backup` (Time Machine) and `reminders` (EventKit), which are macOS-only and stay that way: manual, appTime, appLimit (with window-title filters), activity windows, online checks (GitHub, feeds, Duolingo, LeetCode, Codeforces), notes folders, git commits and desktop tidy. It also has history and streaks, evening and break reminders, and the GitHub username setting, shaped like the macOS app: a tray popover (left-click the tray face) and a resizable main window with a sidebar and the Explore card grid, both hand-drawn to mirror the macOS look. Not done: an installer, signing, auto-updates, onboarding, and Windows CI on pushes.

**Naming:** the blueprint's working name was "Proof". Use **Peeko** everywhere (`PeekoCore`, `Peeko.app`, `com.a7med7x7.peeko`, `~/Library/Application Support/Peeko/`, `User-Agent: Peeko-App`, `Peeko-x.y.z.dmg`).

## Commands

- `make run`: build, bundle and ad-hoc sign `build/Peeko.app`, then relaunch it. Always verify through the `.app`, never `swift run`.
- `make check`: runs `Checks/main.swift` (`PeekoChecks` target), the stand-in for unit tests, since XCTest and Swift Testing both need Xcode. Add a `check(...)` case there for new core logic; it exits non-zero on failure.
- `make dmg`: `build/Peeko-<version>.dmg` + `.sha256`. `make icon` regenerates `Resources/AppIcon.icns` from `scripts/make-icon.swift`.
- `make install`: build and copy into `/Applications`. `install.sh` is the public one-liner that installs the latest GitHub release.
- `make app` / `make clean` / `swift build` (quick compile check)
- Release = bump `CFBundleShortVersionString` in `Resources/Info.plist`, add the matching `CHANGELOG.md` section, push tag `vX.Y.Z`. CI refuses mismatches.

### Windows (`windows/`)

Needs the .NET SDK (8 or newer), not Xcode or Swift. Run from the repo root:

- `dotnet run --project windows/checks/Peeko.Checks`: the Windows equivalent of `make check`. Runs on any OS and exits non-zero on failure. Add a check here for any new core logic.
- `dotnet build windows/src/Peeko.Windows`: compile check. `EnableWindowsTargeting` is on, so this works from macOS or Linux, but the app only runs on Windows.
- `dotnet publish windows/src/Peeko.Windows -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -o windows/dist/<name>`: a self-contained `Peeko.exe` (about 72 MB compressed; it bundles .NET and WinForms, and WinForms can't be trimmed). `windows/dist/`, `bin/` and `obj/` are git-ignored.
- Release: push a `windows-vN` tag. `.github/workflows/release-windows.yml` runs the checks on `windows-latest`, publishes the self-contained exe, and attaches `Peeko-Windows-vN.zip` plus a `.sha256` as a prerelease that is never marked Latest (the Mac download button and `install.sh` follow `releases/latest`). Bump `<Version>` and the `Build` string in `PeekoView.cs` first, and update the zip links in the README and site. There is still no installer or Windows CI on pushes.

## Must-knows

- **Write `@ViewState`, never `@State`.** The macOS 27 SDK's `@State` macro plugin isn't in Command Line Tools ([ViewState.swift](Sources/PeekoApp/ViewState.swift)). `@Observable` works fine.
- Tasks are data: a preset is a JSON edit in `Resources/catalog.json`; a new type is one `Verifier` struct plus a case in `makeVerifier(for:)`. Never hardcode a specific app or task.
- Files on disk carry `schemaVersion`; schema changes are additive only.
- Day keys come from `Calendar.current` (local time), never date strings or UTC.
- `appTime`: tick every 10s and add `min(now - lastTick, 10s)` so sleep never inflates totals; skip ticks when idle > `idleCutoffSeconds`; pause on `willSleep` / `screensDidSleep`. Keep system calls behind `FrontmostAppProvider` / `IdleTimeProvider` protocols so fakes can be injected.
- GitHub: ETag + 10-min poll (unauthenticated 304s still count against the 60/hour limit), compare `created_at` to the local day, show "checking…" until end of day. Any token goes in Keychain.
- `makeVerifier(for:environment:)` needs a `VerifierEnvironment` (GitHub client, username, calendar). Use `isVerifiable(_:)` for "is it supported?".
- This machine runs the LuLu firewall: a new binary's network calls time out until it's allowed. If `curl` works but URLSession doesn't, that's the cause.
- Notify once per task when an *automatic* task flips to done (`Scheduler.onAutoComplete`); never for manual taps. Notifications only work from the bundled `.app`.
- The popover content has a fixed height (`Theme.contentHeight`). A resizing `MenuBarExtra` window drifts off the menu bar.
- A new menu bar icon may hide in macOS's `«` overflow on this machine; that's not a bug.
- Use `/usr/bin/log` (zsh shadows `log`). Missing banners are usually a Focus: look for `muted by DND suppression` in the NotificationCenter logs before debugging code.

### Windows must-knows

- **Build on the macOS app; never replace or restructure it.** Windows work stays inside `windows/` and shared docs. Don't touch `Sources/`, `Checks/`, `Package.swift`, `Resources/catalog.json` or the macOS release workflow for it.
- **The JSON files are the contract.** `windows/` reads and writes the same `tasks.json`, `settings.json` and `days/yyyy-MM-dd.json` shapes, including Swift's enum coding (`{"done":{"at":"…Z"}}`), UTC ISO-8601 dates with no fractional seconds, `schemaVersion` everywhere, additive changes only, atomic writes, and unreadable files moved aside. A change to one side's file shape must be mirrored on the other. Unknown fields (a Mac task's `bundleIDs`) must survive a Windows save (`JsonExtensionData`).
- **Same rules, two implementations.** `windows/src/Peeko.Core` is a port of `PeekoCore`: the 10s tick, `min(now - lastTick, 10s)` credit, idle cutoff, local-day keys, notify once per automatic completion, streaks that only extend today. When a rule changes in Swift, change the C# and add a check on both sides.
- **Windows has its own catalog.** `windows/Resources/catalog.windows.json` uses `processNames` (executable names without `.exe`, case-insensitive) instead of macOS `bundleIDs`. Only ship presets whose type Windows can verify (`VerifierType.IsSupported`). Same rule as the Mac: tasks are data, no hardcoded apps.
- **System calls stay behind `IForegroundAppProvider` / `IIdleTimeProvider`.** The Win32 ones (`GetForegroundWindow`, `GetLastInputInfo`) are in `Peeko.Windows`; checks inject fakes. Pause the tracker on suspend and session lock.
- **The tray app can't be run or screenshotted from macOS or Linux.** `dotnet build` and the checks prove the core and that it compiles, not that it renders. Say so when handing it over, and ask for a screenshot or `%APPDATA%\Peeko\error.log` when something looks wrong. Never claim the Windows UI was verified.
- **The UI is hand-drawn** (`PeekoView`, `Theme.cs`: GDI+, logical px scaled by DPI) to mirror SwiftUI, including the face geometry from the brand file. One view, two hosts in `Hosts.cs`, like macOS: `PopoverForm` (tray, 320 px, fixed height, hides on click-away) and `MainWindow` (sidebar, wide column, Explore grid, 20-week history). Dialogs opened from the view go through `Dialog(...)` so the popover doesn't hide under them. Keep colors and copy in step with the macOS `Theme` and the "Peeko saw that!" tone.
- **Give each test build a new file name and a visible marker** (zip name, footer "build N"). Stale copies of the exe, and a hidden tray icon, caused most of the early "it doesn't work" reports. The app also keeps a single instance (named mutex) and brings its window forward when launched again.
- Data lives in `%APPDATA%\Peeko`. Launch at login is the `HKCU\…\Run` key.

## Brand and copy

- Tone: curious, cheering, never policing. Write "Peeko saw that! Read for 30 minutes ✓", never "Verified".
- Faces: pending/failed → dozing, inProgress → looking, done → beaming. The menu bar icon is an eyes-only template image. On Windows the tray icon is the full face, following the day's mood.
- The tab users see is **Explore**; in code the presets are still `catalog.json` / `CatalogView`. Each `TaskCategory` (how Peeko checks a task) has a color on icons and chips only; status (rings, ticks, faces) stays green.
- Colors (in `Theme`): Peeko green `oklch(0.82 0.15 145)` ≈ `#81DD86`, Night `#151515`, Chalk `#F2F2EF`, Blush `oklch(0.82 0.15 330)`. The brand fonts (Bricolage Grotesque, JetBrains Mono) aren't bundled yet; the UI uses SF Rounded and SF Mono for now.
