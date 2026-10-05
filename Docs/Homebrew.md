# Homebrew integration status

Homebrew distribution is not released yet. Continue using the notarized release and in-app updates. No production Tap/Cask should be published until application replacement is protected for its entire lifetime, including old-app removal and rollback.

## Reproducible contract probe

The optional probe uses the installed Homebrew implementation, synthetic Info.plist files and temporary directories. It does not install a Cask, alter receipts, launch DailyDisk, or access the inventory database:

```bash
HOMEBREW_DEVELOPER=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 \
  brew ruby Scripts/Homebrew/test-contract.rb
```

The explicit developer environment avoids permanently enabling Homebrew developer mode. Homebrew is a prerequisite only for this optional integration probe, not for building or running DailyDisk. Start from default auto-update Cask settings; an environment disabling those updates will intentionally change the expected matrix.

The probe checks actual Cask version discovery and Installer orchestration. It replaces app mutation and receipt-writing operations with observers. A separate real structured preflight runs a short-lived lock holder through Homebrew's normal subprocess/sandbox path. Thus this is evidence about callback boundaries, not full installation or crash-recovery acceptance.

Validated against Homebrew 7.0.7:

- Ordinary auto_updates version checks recognize an app updated by Sparkle and skip a newer actual marketing version when the Tap lags.
- A higher build with the same marketing version can be missed. Public upgrade releases must increase both marketing version and build.
- Greedy checks can use stale receipts even when the installed app is newer. Independent downgrade protection is required.
- Missing Info.plist and installer-only artifacts can be treated as not outdated; this does not establish installation health.
- An upgrade removes old app artifacts before new preflight. Failed installation can omit new postflight before restoring the old artifacts.
- A lock scoped to a preflight child is released before the app artifact executes. It cannot protect the replacement transaction.
- A custom installer without an app artifact loses the actual bundle discovery used by auto_updates. Adding both artifacts causes two independent mutation stages unless ownership is explicitly redesigned.

## Remaining release gate

The declarative Cask must retain ordinary app tracking without exposing unguarded replacement. Investigate a controlled Homebrew transaction entry point with fixed operations and signed installation coordination; direct operations must fail before mutation unless protection is established. The protocol must cover first install, upgrade, reinstall, uninstall, failure, parent/child termination and rollback. A background lock process or elapsed timeout is not proof that all mutation processes have stopped.

Do not modify a published notarized app or Homebrew's receipts. A new runtime protocol requires a new ordinary signed/notarized release before Cask publication. Keep prototype results and machine-specific investigation under `.local-notes/homebrew/`.

References: [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook), [Homebrew Cask implementation](https://github.com/Homebrew/brew/blob/7.0.7/Library/Homebrew/cask/cask.rb), [Installer](https://github.com/Homebrew/brew/blob/7.0.7/Library/Homebrew/cask/installer.rb).

## Native-command implementation branch

The selected direction is to preserve standard `brew install`, `upgrade`, `reinstall` and `uninstall`, not require a replacement command. The first implementation layer adds durable external installation admission; it is not a usable Cask yet.

An explicitly prepared `ready` update may transition to protocol-v2 `externalInstalling` under the installation lease, Control lock and exclusive helper admission lease. The record contains only operation, source/target builds, transaction ID and the original task preference. Failure may transition to `externalRecoveryRequired`; both phases block helper admission, manual/scheduled requests, ordinary Resume, Sparkle installation and source replacement. Callback termination, GUI restart or the presence of the target build cannot clear the record. Legacy manual/Sparkle state remains protocol v1; older releases fail closed on protocol v2.

Admission and failure APIs remain internal and are only exercised by synthetic tests. No executable mode or Cask can enter these states in production yet. There is deliberately no completion/unlock API: the adapter must first establish a terminal boundary covering Homebrew rollback and surviving mutation subprocesses. Build comparisons currently validate intent metadata; they are not verification of the installed app's signature or actual version. First-install admission, trusted bundle verification, finalization, interrupted recovery and the native Cask adapter remain subsequent work.

Tests reopen persisted records, race admission against GUI Resume, preserve enabled/disabled preferences, reject malformed or stale state and prove that a released callback lease does not release the durable gate. The source installer has a separate synthetic rejection test for these states. No inventory schema change is involved.
