# Contributing

DailyDisk targets Swift 6 and macOS 15 or later. It handles sensitive filesystem paths and trusted FSEvents checkpoints, so correctness and privacy invariants take priority over convenience.

See [Installation](Docs/Installation.md) for Apple developer tools, pinned SwiftPM dependencies, signing, and first-run permissions. Source builds do not need Homebrew or a database server.

## Before opening a pull request

```bash
swift format format --in-place --recursive Sources App Tests
swift format lint --recursive Sources App Tests
swift build
swift test
Scripts/lint-launch-agent.sh
ALLOW_ADHOC_SIGNING=1 Scripts/build-app.sh
DAILYDISK_DRY_RUN=1 build/DailyDisk.app/Contents/Helpers/DailyDiskAgent
codesign --verify --deep --strict build/DailyDisk.app
```

For inventory/store performance changes, also run:

```bash
DAILYDISK_RUN_STRESS=1 swift test --filter millionRecordInventory
```

## Required invariants

Changes must preserve:

- event cursor advances only with its fully applied trusted fence
- generation activation and checkpoint update remain atomic
- physical unattributed space never becomes a fabricated path
- corrections retain their sign
- System/Data inventory is not duplicated
- symlinks and nested mounts are not followed
- opaque permission subtrees are not interpreted as deletions
- default notifications, CLI status, and operational logs contain no full paths
- strict CLI inspection does not modify SQLite or sidecar files
- scans remain in the helper; notifications use the bounded, windowless app delivery process
- an optional notification failure cannot invalidate a committed report

Add deterministic tests for event/drop flags, path bytes, hard links, failure transactions, and report/accounting effects introduced by the change.

## Sensitive artifacts

Do not commit or upload:

- generated app bundles
- SQLite databases, WAL, or SHM files
- reports or logs from a real Mac
- unredacted diagnostic exports
- signing certificates, private keys, Team IDs, or notarization credentials
- paths containing a contributor's username

Use synthetic UUIDs, paths, and diskutil/lsof fixtures. `.gitignore` excludes local environment variants, agent configuration, signing/provisioning files, app packages, database sidecars, and diagnostic logs. Ignore rules do not remove already tracked files or inspect their contents; always review `git diff --cached` before publishing. Keep `Package.resolved` tracked for reproducible dependency resolution.

## Migration policy

Never edit a migration that may have been applied by another revision. Add a new numbered migration, update `DailyDiskSchema.expectedMigrations`, and test both fresh creation and upgrade behavior.

## License

DailyDisk uses the MIT License. By submitting a contribution, you agree that it may be distributed under the repository's [MIT License](LICENSE).
