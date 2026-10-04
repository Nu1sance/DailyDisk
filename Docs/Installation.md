# Install from GitHub source

DailyDisk currently ships as source, not a notarized downloadable installer. Other users can build it on their own Mac; they do not need the author's signing certificate, database, or local configuration. The packaging script builds all three executables and installs the app. Developer-tool installation, local signing setup, and macOS privacy approvals remain manual.

## Requirements and dependencies

| Component | Required? | How it is provided |
| --- | --- | --- |
| macOS 15+ and internal APFS startup disk | Yes | Supported runtime/storage scope |
| Apple Command Line Tools with Swift 6+ and macOS 15+ SDK | Yes for building | Install separately; do not assume a stock Mac has a working compiler |
| Full Xcode | Alternative | A compatible full Xcode installation supplies the toolchain and SDK; it is not required for the tested command-line build |
| Git | For cloning | Included in Apple developer tools; downloading a source ZIP is also possible |
| Swift Package Manager | Yes for building | Included with Swift; no separate package-manager install |
| `swift-testing`, transitive `swift-syntax` | Resolved by SwiftPM | Downloaded from GitHub automatically; exact revisions are recorded in `Package.resolved` |
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
open "$HOME/Applications/DailyDisk.app"
```

This creates an app signed for local development only. It is not a persistent-distribution setup: replacing the build can invalidate Full Disk Access or notification grants. Do not use this route to promise unattended updates with preserved permissions.

### Persistent local installation

List existing valid code-signing identities:

```bash
security find-identity -v -p codesigning
```

An identity consists of a certificate **and its private key**. The build script does not create one. If an appropriate Apple Development identity is already available, use its displayed name or hash. A local self-signed Code Signing identity created with Keychain Access is another local-use option; create/trust it as appropriate for code signing and verify that the command above lists it as valid. See Apple's certificate/signing references below. A self-signed certificate is not a Developer ID distribution certificate or notarization.

For an Apple identity:

```bash
CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
  Scripts/build-app.sh --install
open "$HOME/Applications/DailyDisk.app"
```

For your own valid local Code Signing identity, disabling Apple's secure timestamp request is available:

```bash
CODE_SIGN_IDENTITY="DailyDisk Local Signing" CODE_SIGN_TIMESTAMP=none \
  Scripts/build-app.sh --install
```

The names above are examples, not identities included in the repo. Apple membership is not required merely to compile or try the app; obtaining an Apple-issued signing identity is a separate account/setup process. Creating a local certificate remains a manual setup task, not a one-click feature verified across other users' machines.

Keep the same identity, default bundle identifier, and `~/Applications/DailyDisk.app` installation path for updates. Keep the private key on your Mac; never upload/export it into the repository. `BUNDLE_IDENTIFIER` is an advanced pre-authorization option, not support for parallel independent installations: the helper label and runtime data root remain fixed.

## 4. Grant permissions and enable daily work

1. Open **设置 → 磁盘权限** and add the installed `~/Applications/DailyDisk.app` to **System Settings → Privacy & Security → Full Disk Access**.
2. Quit and reopen DailyDisk.
3. On **概览**, choose **启用每日检查**. If prompted, approve DailyDisk in **Login Items & Extensions**.
4. Grant notifications optionally in **设置 → 通用**. Notification denial does not prevent saving reports.
5. Start the first check and wait for the opening baseline. File-growth comparisons begin with the next successful check.

Neither compilation nor a signature grants Full Disk Access automatically. The developer's permissions do not transfer through GitHub. DailyDisk uses a user LaunchAgent; no root helper or `sudo` is needed for normal build/install/use into `~/Applications`.

Current source uses daily full scanning at **05:00 local time**, with incremental attempts only for subsequent manual requests after a published full scan that day. Upgrade the embedded plist, GUI/helper and registered schedule together while preserving signing identity and history. Updates preserve supported existing reports and checkpoints; do not reset inventory as part of a routine update. Verify the registered schedule after updating. See [validation status](DailyFullScan.md). The app need not stay open. A powered-off/logged-out Mac cannot execute its user task; catch-up depends on the next eligible login/wake invocation, not a wake/power-on feature.

## 5. Update or troubleshoot

Before updating, wait for scans and report publication to finish, then select **设置 → 通用 → 软件更新 → 准备安装更新**. This records the original task setting, blocks new scans and unregisters the daily task. Quit the GUI and close CLI inspections; rebuild with the **same signing variables** and `--install`. Reopen the app and select **恢复运行**, whether installation succeeded or was abandoned. This restores only a previously enabled daily task; confirm 05:00 and resolve any system approval prompt. An older installation without this action must use the manual remove-task/quit/install/enable-task procedure. No download or automatic updater is provided yet.

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
