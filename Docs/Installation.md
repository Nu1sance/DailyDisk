# Install from GitHub source

DailyDisk provides MIT-licensed source and signed, notarized Apple Silicon stable archives (starting with 0.2.1 build 16) from [GitHub Releases](https://github.com/Nu1sance/DailyDisk/releases). The notarized release may still display the normal first-open confirmation; see [Apple’s guidance](https://support.apple.com/102445). This guide covers building from source. Other users do not need the author's signing certificate, database, or local configuration. The packaging script builds all three executables and installs the app. Developer-tool installation, local signing setup, and macOS privacy approvals remain manual.

## Requirements and dependencies

| Component | Required? | How it is provided |
| --- | --- | --- |
| macOS 15+ and internal APFS startup disk | Yes | Supported runtime/storage scope |
| Apple Command Line Tools with Swift 6+ and macOS 15+ SDK | Yes for building | Install separately; do not assume a stock Mac has a working compiler |
| Full Xcode | Alternative | A compatible full Xcode installation supplies the toolchain and SDK; it is not required for the tested command-line build |
| Git | For cloning | Included in Apple developer tools; downloading a source ZIP is also possible |
| Swift Package Manager | Yes for building | Included with Swift; no separate package-manager install |
| `swift-testing`, transitive `swift-syntax`, Sparkle 2.10.0 | Resolved by SwiftPM | Downloaded from GitHub automatically; exact revisions are recorded in `Package.resolved` |
| SQLite and Apple frameworks | Yes | System SQLite / SDK; AppKit, SwiftUI, FSEvents, Disk Arbitration, IOKit, ServiceManagement, UserNotifications |
| `diskutil`, `lsof`, `launchctl`, `codesign`, `plutil`, `ditto`, Bash | Yes | macOS system tools; no Homebrew replacements required |
| Stable code-signing identity with private key | For persistent installation | Supplied by each user through Keychain; not distributed in this repository |
| Homebrew, Python, Node.js, Docker, database server | No | Not used by the build/install/runtime workflow |

Internet access is needed for the initial clone/package resolution, and normally for secure signature timestamping. The installed disk monitor makes no application network requests. `swift build` alone produces command-line build products; use the packaging script for the installed GUI and helper resources.

The declared minimum is Swift 6/macOS 15. CI is configured on `macos-15`, using the runner's selected toolchain. This is not proof that every Swift 6/SDK combination works. There is no completed Intel end-to-end acceptance test or universal-binary packaging step; the default script builds for the host architecture.

## 1. Install/check developer tools

```bash
xcode-select --install
```

Complete Apple's installer, then open a new terminal and check:

```bash
xcode-select -p
xcrun --find swift
swift --version
xcrun --sdk macosx --show-sdk-version
git --version
```

Use a matching Apple compiler and SDK with Swift 6+ and SDK 15+. A recent compatible Command Line Tools package is sufficient when the compiler and SDK match. Full Xcode is an alternative if the tools offered for your OS are too old. A separate Swift toolchain without the Apple SDK is insufficient for this SwiftUI macOS app.

If tools are already installed, `xcode-select --install` may say so; update them through Software Update or Apple's developer downloads when necessary. If multiple toolchains are installed, check the selected path and avoid mixing a downloaded compiler with an incompatible SDK. For a full Xcode build you can select it for one command without changing system settings:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

## 2. Get the source

Clone the repository:

```bash
git clone https://github.com/Nu1sance/DailyDisk.git
cd DailyDisk
```

Run the following commands from this directory. Keep `Package.resolved` in the checkout; SwiftPM fetches dependencies automatically. The first build may take considerably longer than subsequent builds. No database initialization or dependency installation with Homebrew is required.

## 3. Choose a signing route

### One-time local trial

No Apple developer membership or preexisting certificate is needed for this explicitly ad-hoc trial:

```bash
ALLOW_ADHOC_SIGNING=1 Scripts/build-app.sh --install
open "/Applications/DailyDisk.app"
```

This creates an app signed for local development only. It is not a persistent-distribution setup: replacing the build can invalidate Full Disk Access or notification grants. Do not use this route to promise unattended updates with preserved permissions.

### Persistent local installation

List existing valid code-signing identities:

```bash
security find-identity -v -p codesigning
```

An identity consists of a certificate **and its private key**. The build script does not create one. If an appropriate Apple Development identity is already available, use its displayed name or hash. With the embedded Sparkle framework, persistent builds need an Apple-issued identity with a Team ID for library validation. A local self-signed identity is no longer supported by this packaging path. See Apple's signing references below. Use Developer ID Application for distribution; an Apple Development signature is not notarized distribution.

For an Apple identity:

```bash
CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
  Scripts/build-app.sh --install
open "/Applications/DailyDisk.app"
```

For your own valid local Code Signing identity, disabling Apple's secure timestamp request is available:

```bash
CODE_SIGN_IDENTITY="DailyDisk Local Signing" CODE_SIGN_TIMESTAMP=none \
  Scripts/build-app.sh --install
```

The names above are examples, not identities included in the repo. Apple membership is not required merely to compile or try the app; obtaining an Apple-issued signing identity is a separate account/setup process. Creating a local certificate remains a manual setup task, not a one-click feature verified across other users' machines.

Keep the same identity, default bundle identifier, and the existing installation path for updates. Keep the private key on your Mac; never upload/export it into the repository. `BUNDLE_IDENTIFIER` is an advanced pre-authorization option, not support for parallel independent installations: the helper label and runtime data root remain fixed.

## 4. Grant permissions and enable daily work

1. Open **设置 → 磁盘权限** and add the installed `/Applications/DailyDisk.app` to **System Settings → Privacy & Security → Full Disk Access**.
2. Quit and reopen DailyDisk.
3. On **概览**, choose **启用每日检查**. If prompted, approve DailyDisk in **Login Items & Extensions**.
4. Grant notifications optionally in **设置 → 通用**. Notification denial does not prevent saving reports.
5. Start the first check and wait for the opening baseline. File-growth comparisons begin with the next successful check.

Neither compilation nor a signature grants Full Disk Access automatically. The developer's permissions do not transfer through GitHub. DailyDisk uses a user LaunchAgent; no root helper or `sudo` is needed for normal build/install/use into `~/Applications`.

Current source uses daily full scanning at **05:00 local time**, with incremental attempts only for subsequent manual requests after a published full scan that day. Upgrade the embedded plist, GUI/helper and registered schedule together while preserving signing identity and history. Updates preserve supported existing reports and checkpoints; do not reset inventory as part of a routine update. Verify the registered schedule after updating. See [validation status](DailyFullScan.md). The app need not stay open. A powered-off/logged-out Mac cannot execute its user task; catch-up depends on the next eligible login/wake invocation, not a wake/power-on feature.

## 5. Update or troubleshoot

Before updating, wait for scans and report publication to finish, then select **设置 → 通用 → 高级操作 → 暂停运行以手动替换应用**. This records the original task setting, blocks new scans and unregisters the daily task. Quit the GUI and close CLI inspections; rebuild with the **same signing variables** and `--install`. Reopen the app and select **恢复运行**, whether installation succeeded or was abandoned. This restores only a previously enabled daily task; confirm 05:00 and resolve any system approval prompt. An older installation without this action must use the manual remove-task/quit/install/enable-task procedure. This manual workflow remains available alongside configured Sparkle updates.

The installer refuses running app/helper/CLI processes, a registered daily task, failed state checks, symlink destinations and changed signing requirements. It stages and verifies the new app before replacing the old one, serializes installations with a lock directory and restores the old app if replacement fails. If rollback itself fails, it preserves the old bundle and prints its location. After an uncatchable interruption, inspect the retained install directory and restore the previous bundle before removing the stale lock. Do not remove a lock while another installer runs.

Keep build output separate from the installation directory. Ad-hoc rebuilds can change signing requirements and are not supported as seamless upgrades over an existing installation. The installer does not unregister tasks, kill processes, migrate databases or back up user data.

- Missing compiler/SDK: install or update Apple developer tools.
- Package fetch failure: check access to GitHub, then retry `swift package resolve`.
- No signing identity: use the explicit trial route or set up a local identity; do not silently disable the signing guard.
- Permission changed after update: verify signing identity, bundle ID, and installation path before regranting access.
- A full scan is slow: see [Operations](Operations.md); duration depends on file count and system load.
- Testing/contributing: see [Testing](Testing.md) and [Contributing](../CONTRIBUTING.md). `swift format` is a contributor lint step; verify it is available in the chosen toolchain.

The repository currently contains CI build/test workflows, not a notarization, release-upload, DMG/PKG, or universal-binary distribution pipeline. A polished download-and-open release would require additional distribution work. This guide does not claim fresh-Mac acceptance testing on all supported hardware.

## Official references

- [Apple: Installing the command-line tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)
- [Swift: Installation on macOS](https://www.swift.org/install/macos/)
- [Apple: Create self-signed certificates in Keychain Access](https://support.apple.com/guide/keychain-access/create-self-signed-certificates-kyca8916/mac)
- [Apple: Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)

## Database rollback

A binary downgrade may not support an upgraded database. Before an update requiring a database rollback plan, retain a matching old application and consistent database backup while the writer is idle. Installation rollback protects the application replacement only; it does not revert database migrations after the updated app runs. Do not reset history as part of a routine update. Keep backups private and outside Git.

### Release version inputs

`Sources/DailyDiskCore/Resources/Product.json` is the source of product version, development build number and minimum OS. GUI and CLI share these values. `dailydiskctl build-number` reports the enclosing installed app's build number, or the source build number for an unpackaged executable.

Release build preparation requires `RELEASE_BUILD=1 BUILD_NUMBER=<next> PREVIOUS_BUILD_NUMBER=<last>` with positive, increasing build numbers (use previous 0 for the first release). Ordinary development builds can use the source default. This is a local input guard, not remote release validation, Developer ID validation or notarization. The release pipeline will supply the authoritative previous build later.

Update preparation persists after GUI exit and does not automatically clear after a timeout or restart. Interrupted scans/pending requests must finish or recover before preparation. If preparation or task restoration fails, retry **恢复运行** after resolving the cause. An active or stale `.DailyDisk-install.lock` blocks recovery as well as installation; use the interruption procedure above. Do not remove it while an installer is active. No database backup, migration, rollback or scan is performed by preparation itself; normal RunAtLoad due evaluation may occur when the task is restored.


## Application updates (Sparkle 2)

The app menu and Settings expose **检查更新…**. Source builds default to disabled updates and show that no update source is configured. Feed/key are explicit packaging inputs, not source defaults. To enable a future distribution build, pass `DAILYDISK_UPDATES_ENABLED=1`, `SPARKLE_FEED_URL` (HTTPS), and `SPARKLE_PUBLIC_ED_KEY` (32-byte base64 public key) to `Scripts/build-app.sh`, alongside the usual signing/version settings. Never pass private signing keys as bundle configuration. Sparkle is pinned in Package.resolved and embedded/signed by the build script.

Checks are user initiated; background checks, automatic downloads and system profiling are disabled. Clicking Install first requires an idle scan/helper and no queued request. DailyDisk durably blocks scanning, remembers whether the daily task was enabled, and unregisters it before allowing download/extraction. The expected new build restores the prior task preference on opening. System approval may still be required. Database/history are not reset or copied by this mechanism.

Cancelling a download before extraction restores the previous task setting. After extraction starts, Sparkle may continue installation outside the app, including on quit. DailyDisk therefore keeps scans paused on interruption; reopen **检查更新…** and finish the pending update. The old build cannot force Resume, and the source installer refuses this state. If the pending release is unavailable or the installer cannot recover, expert recovery must establish that no Sparkle installer remains before removing the gate; there is deliberately no timer-based unlock. Do not manually delete Control files while an installer may still run.

Signed and notarized stable archives are available from https://github.com/Nu1sance/DailyDisk/releases/latest. Both the stable appcast and the legacy testing appcast now advertise the same stable releases so existing installations, including build 16 with its embedded testing URL, continue receiving stable updates. Reserve that legacy URL for compatibility, not experimental builds. New stable packaging should use https://nu1sance.github.io/DailyDisk/appcast.xml. No Homebrew Cask is published. Source builds do not automatically publish or notarize an archive. Before release, run signed two-version acceptance using the real update source: update and relaunch, install on quit, active scan refusal, download cancellation, interrupted extraction/installation, task preference restoration, and Full Disk Access/notification continuity. Explicit ad-hoc development builds use DailyDisk-Development.entitlements to disable library validation because they lack a Team ID. Persistent/distribution builds retain library validation and need an Apple-issued signing identity to load the embedded framework; a local self-signed certificate without a Team ID is no longer sufficient. Ad-hoc packaging checks do not establish distribution readiness.


## Permission continuity and duplicate copies

Keep one installed DailyDisk bundle at its stable path. Store rollback copies as ZIP archives outside Applications, rather than as additional runnable `.app` bundles. Test bundles with the production bundle identifier may become registered with Launch Services even when launched only for diagnostics. Remove those registrations and archive obsolete copies after testing. A separate development application needs distinct bundle/task identities and a separate data root; changing only BUNDLE_IDENTIFIER does not isolate DailyDisk today.

If Full Disk Access turns itself off again after restart, distinguish that system setting from DailyDisk's heuristic probe. Verify the actual launched path, code signature and designated requirements first. A matching Team ID alone does not establish signing continuity. Keep the installer's designated-requirement check; do not treat a signing transition as an ordinary update. After a deliberate identity transition, remove the old DailyDisk entry from Full Disk Access and explicitly add the actual installed bundle again. Reset only this application's permission if needed, never the entire TCC database. Confirm protected-directory access across repeated exits and launches before restoring scans.

Also verify that the registered helper actually starts: SMAppService's enabled status alone is insufficient. A `Launch Constraint Violation` after identity changes requires investigation of signing and registration. Do not globally reset other applications' background-task registrations or disable system signing enforcement as a workaround.

## Update windows and installation destination

Checking for updates closes an open settings sheet before Sparkle starts. When no update exists, dismiss Sparkle's up-to-date message to return automatically to settings. A menu check begun with settings closed leaves settings closed. Installing an update closes settings again if it was reopened during download, then temporarily blocks reopening it while installation proceeds.

The source build script defaults to /Applications. --debug selects Debug compilation and ~/Applications; --user selects ~/Applications with the usual Release compilation. INSTALL_DIR remains an explicit override, but cannot conflict with --debug/--user. RELEASE_BUILD=1 rejects Debug configuration. The script refuses a second production copy in the other standard location. A downloaded ZIP does not choose a destination: users copy the app to their chosen Applications folder. Homebrew Cask defaults to /Applications and supports --appdir (see https://docs.brew.sh/Manpage#global-cask-options); DailyDisk's Cask distribution remains a separate release task.

Sparkle replaces the currently running bundle, so an existing ~/Applications installation stays there and an /Applications installation stays there. Helper registration uses the enclosing bundle; update coordination uses the current user’s private Control directory. Runtime data remains in the current user's Application Support directory in either case.

Preparation/restoration now use Control/.installation.lock, without writing in the application directory. Sparkle handles authorization when app replacement requires it. The source installer uses the same private lock plus an exclusive helper work lease; a small Swift launcher transfers those locks to the installer process. No root scan service is introduced. Source installation to a non-writable directory stops with guidance to use an authorized Finder install or --user; do not sudo the whole build/install script. A legacy .DailyDisk-install.lock beside the app is still treated as an unresolved old installation and must be inspected.

Other user launchd domains conservatively block update preparation and the final install response. Log out other users before updating a shared app, and do not start another login session during the installation. This is a single-user update policy, not an atomic system-wide lock against future logins. Standard-user administrator authorization/cancellation still requires separate real-machine acceptance.

Download/extraction files remain managed by Sparkle’s cache. Only small durable recovery state and reusable coordination files belong in existing Control; state is cleared after safe restoration. Do not put the only recovery state in disposable caches or unlink active flock files. Do not move an already authorized app or retain two production copies merely to change update methods.
