# Contributing to Mac Cleaner Pro

Thanks for considering it — this is a solo-maintained project, so outside
contributions genuinely move the needle, whether that's a one-line fix or a
whole new feature.

Please also read the [Code of Conduct](CODE_OF_CONDUCT.md).

## Dev setup

```sh
brew install xcodegen
xcodegen generate
open MacCleanerPro.xcodeproj
```

Run the test suite before opening a PR:

```sh
xcodebuild -project MacCleanerPro.xcodeproj -scheme MacCleanerPro test
```

For a single test:

```sh
xcodebuild -project MacCleanerPro.xcodeproj -scheme MacCleanerPro \
  test -only-testing:CoreTests/ScanEngineTests/testFoo
```

## Where things live

- Business logic goes in `Core/` (pure Swift, no UI) so it's testable
  without a host app — see `Tests/CoreTests/` for the pattern to follow.
- SwiftUI views/view models go in `App/`.
- The privileged helper's XPC contract is `Shared/HelperProtocol.swift`,
  shared between `App/` and `PrivilegedHelper/` — changes here need care
  since both targets depend on it.
- Any change to Xcode targets, sources, entitlements, or build phases goes
  through `project.yml`, then `xcodegen generate` — never hand-edit the
  generated `.xcodeproj`.

## What's especially useful right now

As a single maintainer, these are the contributions I have the least time
for myself:

- **Testing on hardware/macOS versions I don't have** (older Intel Macs,
  different macOS point releases) and filing precise bug reports.
- **New cleanup rules** for the rule pack (`RulePacks/v1.json`) — safe,
  well-scoped paths for a specific app/tool's cache leftovers. Note: rule
  pack *signing* is maintainer-only (the private key isn't in this repo by
  design — see `docs/rule-pack-signing.md`), but you can absolutely propose
  new rules via PR and I'll sign a release.
- **Localization.** There is a String Catalog at `App/Localizable.xcstrings`
  and the app target extracts into it on every build. To add a language, open
  the catalog in Xcode, hit **+** in the language list, and translate. Two
  things to know before you start: `Text("…")` literals are picked up
  automatically, but strings assembled in Swift (most of the status messages in
  the view models, e.g. `"Moved \(formattedSize(bytes))"`) are **not** — those
  need converting to `String(localized:)` with interpolation placeholders
  first, and that conversion is itself a welcome PR. Right now the catalog is
  empty and English is the only language, so nothing is mistranslated — it's a
  starting point, not a finished pipeline.
- **Docs fixes** — anything unclear in `docs/`.
- **Bug fixes** with a minimal repro.

For larger features (new scan modules, UI overhauls), please open an issue
to discuss the approach before investing a lot of time — I'd rather align
early than ask for a rewrite after the fact.

## Pull request process

1. Fork the repo, branch off `main`.
2. Keep PRs focused — one logical change per PR is much easier to review.
3. Add/update tests in `Tests/CoreTests/` for any `Core/` change.
4. Make sure `xcodebuild ... test` passes locally.
5. Open the PR with a clear description of *why*, not just *what*.

## What not to touch

- `keys/` — the rule-pack private signing key is intentionally never in this
  repo. Don't add key material here, even for testing (use a throwaway
  keypair locally and don't commit it).
- `REPLACE_TEAM_ID` placeholders in `project.yml` / `PrivilegedHelper/*` —
  these get substituted only when the project moves to a paid Apple
  Developer Program; leave them as-is in PRs.
