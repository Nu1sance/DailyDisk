# Homebrew installation and updates

The native-command implementation is on the Homebrew integration branch. Publication of `nu1sance/tap/dailydisk` requires its new signed/notarized release; do not point this Cask at build 16, which has no native installer. Public Tap/release acceptance is still pending.

## User workflow

The intended one-command installation is:

```bash
brew install --cask nu1sance/tap/dailydisk
```

Target: Apple Silicon, macOS 15+, `/Applications`. A user without destination write access may use `--appdir="$HOME/Applications"`; never sudo the installer. Keep one production app across these locations.

Before replacing/removing an existing app, wait for scans, select **Settings → General → Advanced → 暂停运行以手动替换应用**, then quit the GUI/CLI. After replacement, reopen and choose **恢复运行** to restore the prior daily-task preference. First installation needs no preparation. Uninstall retains data/reports; there is no zap stanza.

Standard `brew update`, `brew upgrade --cask nu1sance/tap/dailydisk`, `brew reinstall --cask nu1sance/tap/dailydisk` and `brew uninstall --cask nu1sance/tap/dailydisk` remain the user commands. `update` refreshes metadata; `upgrade` installs eligible updates. Sparkle remains available. Brew decides from its receipt whether to download; the native installer preserves an equal/newer signed actual build, preventing downgrade when Sparkle is ahead. Redundant downloads are possible. Equal-build reinstall is a no-op; invalid signatures are rejected rather than silently overwritten.

After interruption, quit the app and retry the failed Brew command (use reinstall if the receipt is already current). Retry validates signed installed/backup copies under exclusive locks, restores an old copy if replacement never finished, or retains a valid target and completes cleanup. Never delete Control markers to force recovery. Corruption or missing signed copies may need expert inspection.

## Transaction boundary

The Cask has only installer/uninstall scripts invoking the ordinary signed GUI executable in headless modes. No app artifact, global Ruby hooks, wrapper command, resident service or custom receipt writes. It deliberately omits auto_updates: installer-only Casks lack reliable app-version discovery.

Homebrew invokes uninstall callbacks during upgrade/reinstall and rollback. The native parser examines same-user ancestry and argv of standard Apple Silicon/Intel brew.rb paths. These internal callbacks do not remove the app; only explicit uninstall/remove/rm does. Unknown contexts fail closed. Custom Homebrew prefixes and brew bundle are not supported by this protocol.

A single native process holds private installation and exclusive helper admission leases across all synchronous filesystem mutations. No mutating subprocess can survive the lease holder. Protocol-v2 externalInstalling/externalRecoveryRequired persists operation, builds, ID and original task preference; manual/Sparkle records remain v1. GUI restart, elapsed time and postflight never release the gate. Normal completion restores manual ready for explicit task restoration; fresh installation clears its no-task gate. Uninstall clears the gate after app removal.

Signature checks cover the Developer ID identity, nested code and GUI/helper/CLI designated requirements. Build comparisons read the actual plist without Bundle caching. Replacement requires an idle GUI/helper/CLI, unregistered job, single user session and valid destination. Staging and backup live beside the target. Runtime history stays in the original per-user Application Support directory; no database migration.

Homebrew retains its staged Caskroom payload for uninstall/rollback. Do not open it or grant it Full Disk Access. Headless modes do not create NSApplication or register a GUI scene.

## Verification and release maintenance

Run the normal Swift suite and source-installer checks, plus optional integration tests:

```bash
HOMEBREW_DEVELOPER=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 brew ruby Scripts/Homebrew/test-contract.rb
python3 Scripts/Homebrew/test-native-lifecycle.py
python3 Scripts/Homebrew/test-process-death.py
```

The first probe documents actual Homebrew version/flight behavior with observed mutations. The second runs real native commands against a temporary synthetic Tap: install, reinstall, upgrade, newer-app preservation, failure and uninstall. Its production ancestry parser is compiled locally, outside the simulated quarantined download. This is separate from Gatekeeper acceptance. The third SIGKILLs the actual Swift transaction process after copying, old-app removal and new-app placement, then verifies durable blocking and recovery on another invocation. Fixtures never adopt production apps, receipts or inventory.

Scripts/Homebrew/render-cask.py renders the Cask from marketing version, increasing build and final stapled ZIP SHA-256. Publish immutable notarized bytes before updating the Tap. Verify hash, Gatekeeper, native command execution and Cask syntax/style before announcing availability. Keep both established Sparkle feeds stable. Intel, custom prefixes, standard-user and fresh-Mac acceptance are not implied by administrator testing.

References: [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook), [Installer](https://github.com/Homebrew/brew/blob/7.0.7/Library/Homebrew/cask/installer.rb).
