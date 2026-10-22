# Releasing

## Packaging locally

| Command | Output |
|---|---|
| `make app` | `build/Peeko.app`, ad-hoc signed |
| `make dmg` | `build/Peeko-<version>.dmg` (the app plus an Applications shortcut) and a `.sha256` file next to it |
| `make icon` | Regenerates `Resources/AppIcon.icns`, `docs/assets/icon.png` and the full-size `docs/assets/icon-1024.png` from `scripts/make-icon.swift` |
| `make social` | Regenerates `docs/assets/social-preview.png` (1280×640) from `scripts/make-social.swift`. Upload it in the repo's **Settings → General → Social preview**; GitHub has no API for this. |

The icon is drawn in code from the brand geometry: Peeko hanging from a menu bar strip on a Night-colored body. The generated `.icns` is committed, so builds don't need to redraw it. Change the script and rerun `make icon` to update it.

## Versions

- `CFBundleShortVersionString` in `Resources/Info.plist` is the version people see, and it follows SemVer. It's the single source of truth.
- `CFBundleVersion` is the build number. CI sets it to the workflow run number through `BUILD_NUMBER`. Local builds keep the value from `Info.plist`.

## Cutting a release

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`.
2. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [x.y.z] - YYYY-MM-DD` and add a fresh `## [Unreleased]` above it.
3. Commit, then tag and push:
   ```sh
   git tag vx.y.z
   git push origin main vx.y.z
   ```
4. `.github/workflows/release.yml` then:
   1. checks that the tag matches `Info.plist`
   2. runs `make check`
   3. builds the DMG
   4. takes the release notes from that version's CHANGELOG section
   5. signs the DMG for Sparkle and writes `appcast.xml` (`scripts/appcast.sh`)
   6. publishes a GitHub Release with the DMG, its checksum, a copy named `Peeko.dmg` (the site's Download button points at `releases/latest/download/Peeko.dmg`), and `appcast.xml`

   The workflow fails if the tag and version don't match, if the CHANGELOG has no section for that version, or if the `SPARKLE_PRIVATE_KEY` secret is missing.

Before tagging, install the DMG on a second Mac (or a fresh user account) and make sure it launches.

`install.sh` (served at https://peeko.stack42.tech/install.sh by the Pages workflow, and also from `main` on raw.githubusercontent.com) installs whatever `/releases/latest` points to, so a new release reaches script users as soon as it's published. It needs both the `.dmg` and the `.sha256` attached. It refuses to install if the checksum doesn't match.

## Signing and Gatekeeper

Releases are **ad-hoc signed** for now (`scripts/sign.sh` with no identity). That's free, but a downloaded copy is quarantined, and macOS blocks it the first time it opens. Since macOS 15, right-click → Open no longer gets past this. People need to:

1. Open Peeko once and dismiss the warning.
2. Go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the Peeko message.
3. Confirm with their password or Touch ID.

Building from source skips this, because a locally built app isn't quarantined.

When strangers start downloading it, the next step is a **Developer ID** certificate (Apple Developer Program, $99/year) plus notarization:

- Set `SIGN_IDENTITY` for `scripts/sign.sh`.
- Add the hardened runtime and a timestamp to the `codesign` call.
- Submit the DMG with `xcrun notarytool submit --wait`.
- Staple the result with `xcrun stapler staple`.

In CI, the certificate (as base64) and an app-specific password go in repository secrets.

## Auto-updates (Sparkle)

Installed copies use [Sparkle](https://sparkle-project.org) 2, pulled in by SwiftPM as a prebuilt framework and copied into `Contents/Frameworks` by `scripts/bundle.sh`.

- **Feed:** `SUFeedURL` is `https://github.com/STACK-42/peeko/releases/latest/download/appcast.xml`. Each release uploads a one-item `appcast.xml`, so the newest release's feed is the only one ever served. Windows releases are prereleases and never Latest, so they don't get in the way.
- **Signing:** Sparkle installs an update only if the DMG's Ed25519 signature matches `SUPublicEDKey` in `Info.plist`. `scripts/sign-update.swift` signs with CryptoKit; the private key (a base64 32-byte seed) is the `SPARKLE_PRIVATE_KEY` repository secret, with a backup in the maintainer's login Keychain under "Peeko Sparkle signing key". If the key is lost, installed copies can't take signed updates anymore and people have to reinstall by hand once, so keep the backup.
- **Ad-hoc signing:** an ad-hoc signature's default designated requirement is that build's exact hash, and Sparkle refuses an update whose signature doesn't satisfy the old app's requirement. So `scripts/sign.sh` pins the requirement to `identifier "com.a7med7x7.peeko"`. The EdDSA signature is what proves an update came from us. The pinned requirement also keeps the Keychain item and the Accessibility permission across updates. Sparkle clears the quarantine flag on what it installs, so updates skip the Gatekeeper dance.
- **Checks:** once a day (`SUEnableAutomaticChecks`), plus **Settings → Check now**. Scheduled alerts are "gentle" since Peeko is a menu bar app.
- **Local test:** build an older version, point it at a local feed with `defaults write com.a7med7x7.peeko SUFeedURL http://localhost:8000/appcast.xml`, serve `build/` with `python3 -m http.server`, and check from Settings. `defaults delete com.a7med7x7.peeko SUFeedURL` puts it back.

## Windows

The Windows app in `windows/` has its own tags, `windows-v1`, `windows-v2` and so on, never `vX.Y.Z`. Pushing one runs `.github/workflows/release-windows.yml`, which:

1. runs `windows/checks/Peeko.Checks`
2. publishes a self-contained `Peeko.exe` for win-x64
3. zips it as `Peeko-Windows-vN.zip` with a `.sha256` next to it
4. creates a prerelease that is never marked Latest, so `releases/latest` (the Mac download button and `install.sh`) keeps pointing at the Mac release

Before tagging, bump `<Version>` in `windows/src/Peeko.Windows/Peeko.Windows.csproj` and the `Build` string in `PeekoView.cs`, then point the README and site links at the new zip.

## Not yet

- Note that **launch at login** (`SMAppService`, in Settings) works best when the app lives in `/Applications`. Registered from `build/`, it points at that copy.
