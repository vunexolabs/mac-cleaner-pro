# Security policy

Mac Cleaner Pro deletes files on your Mac, so "trust us" is not an acceptable
answer. This document describes exactly what the app is allowed to touch and
what stops it touching anything else — every claim here points at the code or
data that implements it, so you can check rather than believe.

## The security model

### What files can be touched

Two independent sources decide this, and nothing else is scannable:

- **The rule pack** ([`RulePacks/v1.json`](RulePacks/v1.json)) — 21 rules with
  explicit path globs. 14 are developer artefacts, 3 browser caches, 2 caches,
  1 logs, 1 mail. Nothing outside a rule's `paths` is ever a candidate.
- **Folders you point at** — Large & Old Files, Space Lens and Developer Junk
  scan roots you choose.

### Protected paths

The developer scanner refuses to descend into `/System/`, `/Library/`,
`/Applications/` or `~/Library/`, even if you explicitly hand it one as a root.
`/private` is deliberately *not* blocked, because `/var` and `/tmp` resolve
there. See `Core/DeveloperScanner/DeveloperScanner.swift`.

Cleaning user caches additionally skips **17 Apple caches by name** — Safari
webpage previews, CloudKit, HomeKit, Photos, Contacts, Apple Media Services,
Music, TV, Mail, Notes, Find My, News, Maps, Spotlight suggestions and iCloud
sync among them. They free little and cost re-downloads and re-indexing. The
list is the `excludes` array on the `user.caches` rule.

### Symlink policy

Symlinks are never followed — the walker calls `skipDescendants()` on any
symbolic link, so a link inside a scanned folder cannot be used to reach a
protected path. `.app` and `.framework` bundles are treated as opaque via
`.skipsPackageDescendants`.

### Rule-pack signing

Rule packs say *which files may be deleted*, so a tampered pack is a code-
execution-equivalent problem. Packs are Ed25519-signed and verified at runtime
against a public key compiled into the app; verification failure rejects the
pack outright rather than falling back to an unsigned copy. See
[`docs/rule-pack-signing.md`](docs/rule-pack-signing.md) and
`Core/RulesEngine`. The public key is in `keys/rulepack_public.pem`; the
private key is not in this repository.

### Trash-first deletion

Nothing is ever `rm -rf`'d — not by Smart Scan, not by the developer scanner.
Every removal is a *move* into `~/.Trash/MacCleanerPro/<UUID>/`, routed through
a single `DeletionService`. If you disagree with a clean, the files are still
on disk.

### Undo

Each cleanup writes a token that is persisted outside the Trash and re-hydrated
at launch, so Undo survives quitting the app. Staged files remain recoverable
for 30 days, after which a sweep clears them — or until you empty the Trash
yourself, whichever comes first.

### Privileged operations

The app is **not** sandboxed (it needs Full Disk Access to see what's using your
disk) and ships a `SMAppService` root daemon for system-level cleanup. That
helper requires a Developer-ID-signed binary, which this project does not yet
have, so **it is not registered and not running** in current builds. Exactly one
rule (`system.caches`) and the six system-space uninstaller categories depend on
it, and both stay switched off until it ships.

### Release verification

Current builds are **ad-hoc signed and not notarized** — macOS will ask you to
approve the first launch, and that warning is accurate. Until the project has an
Apple Developer Program membership, the substitute is a published SHA-256:

```sh
shasum -a 256 -c MacCleanerPro-<version>.dmg.sha256
```

The sidecar ships with every release and the hash is printed in the release
notes. If it doesn't match, don't open the file — report it.

### No telemetry

The app has no analytics SDK, no crash reporter and no auto-updater. A fresh
install makes no network calls at all. The single exception is a legacy
pre-open-source licence key, which is revalidated with the server periodically
and works offline for up to seven days between checks; without such a key,
nothing is ever sent.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security reports. Instead,
email **abdul.hakeem5764@gmail.com** with:

- A description of the issue and its impact.
- Steps to reproduce (a minimal repro is very helpful).
- Which version/build you tested against.

You should get a response within a few days — this is a solo-maintained
project, so please be patient. I'll credit reporters (unless you'd rather
stay anonymous) once a fix ships.

## Scope

Particularly interested in reports involving:

- The Ed25519 rule-pack signature verification (`Core/RulesEngine`).
- The privileged XPC helper's authorization checks (`PrivilegedHelper`,
  `Shared/HelperProtocol.swift`).
- Keychain-stored legacy licence data (`Core/Licensing`).
- Anything that could cause the app to delete files outside the paths a user
  explicitly targeted.

## Out of scope

- Bypassing a licence or trial gate — there isn't one. The app is free and
  every feature is unlocked, so this isn't a security issue.
- Issues that require physical access to an already-unlocked Mac.
