# Security policy

## Supported version

DailyDisk is currently pre-1.0 and supports the latest source revision on macOS 15 or later.

## Reporting a vulnerability

Do not attach a real DailyDisk database, report, or path-bearing diagnostic export to a public issue. Submit reports through [GitHub private vulnerability reporting](https://github.com/Nu1sance/DailyDisk/security/advisories/new). If that endpoint is unavailable, do not publish exploit or path data; contact the repository owner through the private contact method listed on the GitHub profile first.

Include:

- commit SHA and macOS version
- whether the app was persistently signed or ad-hoc signed
- the affected component and reproduction steps
- redacted logs or `dailydiskctl diagnostics` output

Exclude usernames, home paths, inventory databases, report JSON, notification screenshots containing personal information, and signing certificates.

## Security model

- No telemetry or upload of inventory/reports. User-initiated software updates contact GitHub Pages and GitHub Releases through Sparkle; source checkout/package resolution and signature timestamping also use the network.
- No shell interpolation for system commands
- No root scanning helper, `sudo`-based installation, setuid executable, or LaunchDaemon. Sparkle may request administrator authorization to replace an application in a protected location.
- User-domain LaunchAgent only
- Full Disk Access is manual and does not bypass SIP/POSIX controls
- Descriptor-relative traversal with no symlink following
- External/removable/disk-image APFS containers excluded by default
- One exclusive writer process lease and atomic generation/checkpoint transactions
- Private `0700` directories and `0600` databases/logs/reports/state
- Default CLI/log/notification output omits or hashes paths
- Installed use requires a stable signing identity

The SQLite inventory necessarily contains sensitive local paths. Anyone who can read the current user's Application Support directory or execute code as that user may be able to read it. DailyDisk does not claim protection from a compromised user account.

## Signing

Never commit certificates, private keys, Team IDs, notarization credentials, or a populated `Config/Local.xcconfig`. Build scripts accept signing identity through the environment. Ad-hoc signing must be explicitly enabled and is development-only because privacy grants may not survive rebuilds.

Scheduled notifications use a bounded child process of the same signed app, with aggregate-only input, no GUI scene, no authorization request, and no inventory writes. Child failure is isolated from scan/report completion. See [Operations](Docs/Operations.md).
