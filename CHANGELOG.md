# Changelog

All notable changes to Peeko are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Peeko now starts at login by default, so it's there every time you sign in. It turns this on once, the first time you open this version; switch it off in Settings and it stays off.

### Added

- An optional GitHub token in Settings, so pushes to private repos count too. Peeko keeps it in your Keychain and sends it only to GitHub. A classic token with the repo scope works.
- "Solved a LeetCode problem" and "Solved a Codeforces problem": an accepted solution today, checked like the GitHub push (Codeforces' official API; LeetCode's public GraphQL, which is unofficial). When a site can't be reached, the task says so.

- "Stay under" tasks: keep time in an app (or on a site) below a limit. Ships with "Under 45 min of YouTube". The ring shows time used and turns pink near the limit. Going over marks it missed for the day; staying under counts as done when the day ends.
- The custom app-time form can now be "at least" or "at most".
- A full window: "Open window" in the popover (⌘O) opens Peeko in a resizable window that can go full screen. It has a sidebar for Today, Catalog, History (20 weeks) and Settings, switched with ⌘1–4. While it's open, Peeko shows in the Dock and ⌘Tab. Its Catalog is a card grid with a search bar (⌘F) and category filters (time in apps, limits, writing, sleep & mornings, online, tap it yourself).
- New presets, all things your Mac can check:
  - "Stopped working by 11 PM", "Lunch away from the screen" (a 30-minute break between 12 and 3) and "Took your breaks" (four 5-minute breaks between 9 and 6), from your keyboard and mouse activity.
  - "Under 8 hours of screen time" and "No social media before noon".
  - "One 50-minute focus block": 50 minutes straight in your editor; a quick glance elsewhere is fine.
  - "Practice music" (GarageBand, Logic, Ableton) and "Design" (Figma, Sketch); "Read for 30 minutes" now also counts Books and Kindle.
  - "Wrote today's daily note", "Committed code today" (your local git repos), "Clean Desktop by evening", "Backed up with Time Machine" and "Cleared today's Reminders".
  - "Published something" (any RSS or Atom feed) and "Did a Duolingo lesson".
- Time-window tasks are settled when the day ends, even if your Mac slept through midnight.

### Removed

- The "Gym" and "Drink water" presets: Peeko can't check them, and the catalog is for things it can. If you had them on, they stay under "Your tasks" until you remove them.

### Added (continued)

- When the GitHub check can't get an answer, the task says why (offline or blocked, unknown username, rate limit) instead of "checking…".
- Website limits read the front window's title, which needs Accessibility permission. Peeko asks only when you turn such a task on. Whole-app limits need no permission.

## [0.2.0] - 2026-10-10

Peeko notices more: sleep, early mornings, writing, and a history of how your days went.

### Added

- "Slept on time": passes when there's no keyboard or mouse activity between 00:30 and 05:00.
- "Up before 8": passes when your first stretch of activity after 04:00 starts before 08:00.
- "Write in your notes" and "Write 300 words": pick a notes folder or Obsidian vault, and Peeko ticks these when a note changes today or when you've added enough words.
- Days now record when you were active (stretches of keyboard and mouse use), stored in the day file.
- History tab: your streak (days in a row with at least one thing done), a five-week calendar of how much got done each day, and a streak plus a 30-day count for every task. The streak also shows in the header.
- Settings → Export JSON: your tasks, settings and every day in one file.

### Changed

- GitHub Actions workflows use the Node 24 versions of their actions.

## [0.1.0] - 2026-10-10

First release.

### Added

- Menu bar app with a Today list and a Catalog of presets.
- Manual tasks, including your own custom ones.
- Tasks that count active time in an app (Read in Preview, Deep work in VS Code / Terminal), plus custom ones for any app. Idle time isn't counted, and a sleeping Mac never adds time.
- Everything is saved locally in `~/Library/Application Support/Peeko/`, one file per day, and the list starts fresh each morning.
- "Push to GitHub" task: checks your public GitHub activity every 10 minutes for a push made today, in your own time zone.
- Settings: GitHub username, evening reminder time, launch at login, and a shortcut to your data folder.
- Notifications: one when Peeko ticks something off for you, and an optional evening reminder when tasks are left.
- Break reminders: after an hour of active screen time, Peeko suggests a 5-minute walk. Stepping away for 5 minutes resets the count. The interval is adjustable (30–120 minutes), or turn it off.
- First-launch onboarding.
- App icon, DMG, and a one-line installer (`install.sh`).
