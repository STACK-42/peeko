<p align="center"><img src="docs/assets/icon.png" width="128" alt="Peeko app icon"></p>

# peeko

[![CI](https://github.com/STACK-42/peeko/actions/workflows/ci.yml/badge.svg)](https://github.com/STACK-42/peeko/actions/workflows/ci.yml)

**The to-do list that checks itself.** A small app for Mac and Windows: you do the thing, your computer sees the evidence, and Peeko ticks it off. **[peeko.stack42.tech](https://peeko.stack42.tech)**

Most of us finish a task and go straight to the next one without ticking the last. A lot of a normal day happens on a computer, and a lot of that can be checked, so Peeko does the ticking and you look at the list at the end of the day. Keep your usual to-do list for everything else.

Peeko lives in the Mac menu bar or the Windows tray and keeps an eye on what you're doing. Keep a PDF open for half an hour and "Read for 30 minutes" ticks itself. Push to GitHub and that one goes green as well. Log off by 11 and it notices that too.

Everything in Explore is something your computer can check, so your evening isn't spent ticking boxes. You can still add a few tasks of your own and tap them yourself.

Peeko isn't strict about any of it. Think of a little green creature that notices when you got something done and looks pleased about it.

The Mac app is the main one. The Windows version is an early preview, built by [Asmaa Farouq](https://github.com/Asmaa6777).

## Where it's at

Early days. What works right now on the Mac (Windows has all of it except the Time Machine and Reminders tasks):

- the menu bar icon and popover, with a **Today** list and an **Explore** page of presets, plus a full window when you want more room
- manual tasks, plus your own custom ones
- tasks that count time in an app, like reading in Preview or deep work in your editor, including ones you set up yourself
- a daily "did I push to GitHub?" check
- "slept on time", "up before 8", "stopped working by 11", "lunch away from the screen" and "took your breaks", all from when you were actually at the keyboard
- "write in your notes" and "write 300 words", watching a notes folder or Obsidian vault you pick
- "stay under" limits, like under 45 minutes of YouTube, under 8 hours of screen time, or no social media before noon
- a 50-minute focus block in your editor, without wandering off
- "committed code today" across your local repos, "wrote today's daily note", a tidy Desktop, a Time Machine backup, and cleared Reminders
- "solved a LeetCode problem" or "solved a Codeforces problem" today
- "published something" for any blog or newsletter with an RSS feed, and a Duolingo lesson
- a note when Peeko ticks something off for you, and an optional evening reminder if anything's left
- a gentle nudge to get up and walk for 5 minutes after every hour at the screen (stepping away for 5 minutes resets it)
- a History tab with your streak, a five-week calendar, and how often you did each task
- export everything to one JSON file
- starts when you log in, so it's always there (you can turn that off in Settings)
- everything saved locally, with a fresh list each morning

Peeko updates itself: it looks for a new version once a day, and **Settings → Check now** looks right away. That starts with v0.3.0; on v0.2.0 or older, install the new version once by hand.

## Install

### Mac

Paste this into Terminal:

```sh
curl -fsSL https://peeko.stack42.tech/install.sh | bash
```

It downloads the latest release, checks its checksum, puts Peeko in Applications, and opens it. Run it again any time to update. [Read the script](install.sh) first if you like; it's short.

Or do it by hand: [download the latest DMG](https://github.com/STACK-42/peeko/releases/latest/download/Peeko.dmg) (or pick a version from [Releases](https://github.com/STACK-42/peeko/releases)), open it, and drag Peeko into Applications. Peeko isn't signed with an Apple Developer ID yet, so macOS will block it the first time you open it:

1. Open Peeko once and close the warning.
2. Go to **System Settings → Privacy & Security** and scroll down.
3. Click **Open Anyway** next to the Peeko message, then confirm.

You only have to do that once. The install script and building from source both skip it.

To uninstall, quit Peeko, then delete `/Applications/Peeko.app`. If you want your history gone too, delete `~/Library/Application Support/Peeko`.

### Windows

[Download Peeko for Windows](https://github.com/STACK-42/peeko/releases/download/windows-v1/Peeko-Windows-v1.zip) (v1, Windows 10 or 11, 64-bit), unzip it somewhere you'll keep it, and open `Peeko.exe`. Peeko isn't signed yet, so Windows may show "Windows protected your PC" the first time: click **More info**, then **Run anyway**. You only have to do that once.

Look for the Peeko face in the tray (it may be tucked under the `^` arrow). Left-click it to open Peeko, or right-click for a quick menu. To have it start with Windows, turn on launch at login in Settings.


## How to use it

1. **Open Peeko.** Click the eyes in the menu bar on a Mac, or the Peeko face in the tray on Windows. The first time on a Mac, Peeko says hi, asks if it can send you notes, and asks for your GitHub username (you can skip that).
2. **Pick your tasks in Explore.** Flip the switch next to anything you want on your daily list, like "Read for 30 minutes" or "Push to GitHub". Some ask for one more thing when you turn them on, like a notes folder, a username or a feed link. Search for what you're after, or browse by group.
3. **Add your own if you like.** At the bottom of Explore, type a task and press Add for something you'll tick yourself. On a Mac you can also pick any app and set a time to spend in it (at least) or stay under (at most).
4. **Get on with your day.** Peeko watches quietly and ticks tasks off in **Today** as it sees them happen, with a little note when it does. Tasks it can't check, like your own, you tap to tick.
5. **Look back in History.** See your streak, a calendar of past days, and how often you did each task.

Every morning you get a fresh list with the same tasks. Change your mind any time: switch a task off in Explore and it's gone from Today.

**Settings** has your GitHub username, the evening reminder and its time, the break reminder and how often it nudges you, launch at login, and export. Want more room? Click **Open window** for a full window with a sidebar.

On Windows, closing the window keeps Peeko in the tray. Right-click the tray face for a quick menu, or use **Quit** to exit.

## Privacy

There are no accounts, servers, or analytics. Your tasks and history are plain JSON files in `~/Library/Application Support/Peeko/` on a Mac and `%APPDATA%\Peeko` on Windows, so you can read them, back them up, or delete them whenever you like.

If you turn on the GitHub task, Peeko asks GitHub's public API for your public activity every 10 minutes, using the username you gave it. That's the only network request it makes. Private repos only count if you add a GitHub token in Settings (on a Mac). Peeko keeps it in your Keychain and sends it only to GitHub.

## How it decides you did something

Peeko only looks at a couple of simple signals:

- **Time in an app:** which app is in front, and whether you've touched the keyboard or mouse in the last couple of minutes. If both hold, the minute counts.
- **GitHub:** whether your activity shows a push made today, in your own time zone. That's public pushes, plus private ones if you've added a token.
- **When you're at the computer:** the stretches of keyboard and mouse activity, used for the sleep and early-morning tasks. It only sees the computer, not your phone in bed.
- **Website limits:** the title of the front window, to spot sites like YouTube. This needs Accessibility permission, and Peeko only asks when you turn on a limit that uses it.
- **Your notes folder:** which `.md` and `.txt` files changed today and how many words were added. Only the folder you pick, and nothing leaves your computer.

These signals are easy to fool. Leave a PDF open and nudge the mouse now and then, and it will count as reading. That's fine: Peeko is there to nudge you, and fooling it only fools yourself.

## Build it yourself

### Mac

You need macOS 14 or later on an Apple silicon Mac, and Apple's Command Line Tools (`xcode-select --install`). You don't need Xcode.

```sh
git clone https://github.com/STACK-42/peeko.git peeko
cd peeko
make run
```

That builds `build/Peeko.app` and opens it. Use `make install` instead to put it in Applications (launch at login works best from there). Look for the eyes in your menu bar. If your menu bar is crowded, macOS might hide the icon behind the `«` overflow; ⌘-drag it somewhere you can see it.

### Windows

You need Windows 10 or 11 and the [.NET SDK](https://dotnet.microsoft.com/download) (8 or newer).

```sh
git clone https://github.com/STACK-42/peeko.git peeko
cd peeko
dotnet run --project windows/src/Peeko.Windows
```

To get a single `Peeko.exe` you can keep, see the [Windows notes](windows/README.md).

## Docs

- [Development setup](docs/development.md): toolchain, commands, and quirks
- [Windows](windows/README.md): the Windows version, how it's laid out, and what it covers
- [Architecture](docs/architecture.md): how the pieces fit together
- [Releasing](docs/releasing.md): packaging, versions, and signing
- [Blueprint](docs/blueprint.md): the original plan and roadmap
- [Brand](docs/brand/): the Peeko character, colors, and faces

## License

MIT. See [LICENSE](LICENSE).
