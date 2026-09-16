# Ship Readiness — v1.0.3 ($0-mode)

This document maps every feature to its current state and calls out which capabilities require an Apple Developer Program membership ($99/yr) to unlock.

> Keep this file honest. It is the first place a contributor looks for what
> works, and stale rows here have twice propagated into the README and the
> in-app copy as promises the code did not keep.

## ✅ Working in $0-mode

| Feature | Notes |
|---|---|
| Onboarding wizard | 3-step: Welcome → Full Disk Access → Done. Re-shown on next launch via Settings → Advanced. |
| Full Disk Access detection | Probe via `~/Library/Mail` + `~/Library/Safari/Bookmarks.plist`. Deep-link to System Settings. |
| Smart Scan (user-space rules) | Bundled rule pack v1.1 with 21 rules. Helper-required rules display "Requires helper" badge. |
| Large & Old Files | User-picked root, size + age filters, sortable table, Quick Look preview, Move to Trash. |
| Space Lens | Sunburst and treemap views over a recursive, cancellable scanner. Opens on the sunburst; the choice is remembered. No pause/resume — cancel and rescan. |
| Memory Manager | Live RAM gauge, top-consumer list, Quit Selected (graceful, behind a confirmation), and Quick Free — which applies memory pressure so the kernel drops cached pages, and is skipped with a stated reason when the Mac is already swapping. There is no purge without root; see MemoryFreer's doc comment. |
| App Uninstaller | Discovers `/Applications` + `~/Applications`. 12 user-space + 6 system-space leftover categories. |
| Trash + Undo | All deletions stage at `~/.Trash/MacCleanerPro/<UUID>/`. Tokens persist to disk and are re-loaded at launch, so Undo survives relaunch and is offered per-entry in the Activity Log. A sweep clears staging older than 30 days. |
| Activity Log | JSON-backed at `~/Library/Application Support/MacCleanerPro/activity.json`. Auto-logged from `DeletionService`. |
| License manager | The app is free and open source — every feature is unlocked and there is no trial. `LicenseManager` survives only to recognise legacy pre-open-source keys, shown as a "Supporter" badge in Settings. Ed25519-verified, stored in Keychain. |
| License gate | Nothing is gated. `LicenseGate.canCleanNow` is unconditionally true; the type remains only to drive the legacy Supporter badge. |
| Settings | Appearance / License / Privacy / Advanced. License badge shows offline mode when in grace period. |
| ~~Payment + license delivery~~ | **Historic.** The app went free and open source; there is nothing to buy. The Razorpay/Resend flow described below lives in a separate web repo and is retained here only as a record of how legacy keys were issued. |
| About + Help menu | Standard macOS About box + Help / Buy License menu items. |
| DMG packaging | `tools/build-release.sh` produces a drag-to-Applications DMG, ad-hoc signed. |

## 🔒 Blocked until Apple Developer Program ($99/yr)

| Feature | What unblocks it |
|---|---|
| Privileged helper (system caches, system uninstaller leftovers) | `SMAppService.daemon` registration requires a Team-ID-bearing code signature. Replace `REPLACE_TEAM_ID` in `project.yml`, `PrivilegedHelper/Info.plist`, and `PrivilegedHelper/CodeSignValidator.swift`. |
| Notarization | `xcrun notarytool` needs an active Developer Program membership. |
| Gatekeeper-clean first launch | Notarization stapling. Until then, users do right-click → Open once. |
| Sparkle auto-updates | Works technically without paid cert, but EdDSA + signed binaries is the only sane path. |
| Mac App Store | Separate sandboxed target, requires App Store Connect. |
| Setapp listing | Requires Developer Program membership. |

To upgrade: in `project.yml` set `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY: "Developer ID Application: <Name> (TEAMID)"`, replace `REPLACE_TEAM_ID` in the three files above, then re-run `tools/build-release.sh`. Notarization is a single `xcrun notarytool submit` call per the script's header comment.

## 📋 Pre-launch checklist

### Desktop
- [ ] Update `project.yml` `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` for the release.
- [ ] Tag a release in git (`git tag v1.0.0 && git push --tags`).
- [ ] Run `./tools/build-release.sh`.
- [ ] Test the DMG on a clean Mac (or fresh user account): drag to Applications, right-click → Open, complete onboarding, run Smart Scan, run Large Files, run Uninstaller, verify Undo round-trips, verify Memory Manager is gated on expired trial.
- [ ] Upload `out/MacCleanerPro-1.0.0.dmg` to `web/public/download/` and update the download link in `web/content/site.ts`.

### Web / payments (historic — separate repo, nothing to buy)
- [ ] Set all env vars in Netlify site settings (see `web/.env.example` and `CLAUDE.md` for the full list).
- [ ] Apply `web/supabase/migrations/001_initial_schema.sql` to your Supabase project.
- [ ] Register the Razorpay webhook at `https://maccleanerpro.com/.netlify/functions/razorpay-webhook` for events: `payment.captured`, `payment.failed`, `refund.created`.
- [ ] Verify a test purchase end-to-end: pay → license email arrives → key activates in the app → `activations` row appears in Supabase.
- [ ] Rotate the Resend API key (old key was accidentally stored in `.env.example`).

## 🛣️ Recommended post-launch sequence

1. **First $99 of revenue → buy Apple Developer Program.** Re-cut a notarized DMG; existing users update by re-downloading.
2. **Sign + ship the privileged helper.** With Team ID in place, system-level cleanup features (system cache rules, system-space uninstaller leftovers) turn on automatically — no code changes needed beyond the three `REPLACE_TEAM_ID` substitutions.
3. **Wire Sparkle** for auto-updates so users don't have to manually re-download.
4. **Add Sentry / analytics.** Stubs are in `web/lib/analytics.ts`; wire to your provider of choice.
5. **International payments.** Razorpay covers India (INR). Add Paddle or Stripe for USD/EUR customers using the stubbed env vars in `.env.example`.
