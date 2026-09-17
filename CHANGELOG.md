<!--
  GENERATED FILE — do not edit by hand.
  Produced by web/scripts/gen-changelog.mjs from the site's release notes.
  Edit those and re-run `npm run changelog` instead; a PR against this file
  will be overwritten by the next release.
-->

# Changelog

All notable changes to Mac Cleaner Pro. Newest first.

## [1.0.7] — 2026-09-17

**Undo that actually works, and a UI that scales**

### Added & changed

- Text now follows your system text size. The whole interface was built with fixed point sizes and ignored Accessibility → Display → Text Size entirely; every screen has been moved onto a scale that responds to it.
- Dark mode reworked — a softer canvas, cards that read as cards, and the stray rectangle that appeared across every screen is gone.
- One permissions screen instead of prompts scattered through the app. It explains what macOS needs and why, shows live status, and offers to relaunch when Full Disk Access is granted — because macOS only applies that at launch.
- Cleaned files can now be deleted outright instead of staged in the Trash, for anyone who wants it. Trash-first stays the default and turning it off asks first.
- Scans survive switching tabs. A long Space Lens walk is no longer thrown away when you look at another screen.

### Fixed

- Undo across a relaunch never worked on a real Mac. Its records lived inside ~/.Trash, which macOS will not let an app list without Full Disk Access, and the failure was silent. They now live in Application Support and reload as intended.
- Space Lens, Duplicate Finder and Large & Old Files rendered underneath the title bar, with headings colliding with the window title.
- The size sliders drew a stray dashed line; macOS was rendering a tick mark for every step.
- The app icon showed as a white card inside a grey square rather than filling its tile, and the sidebar logo carried the same white background.

_109 unit tests · universal binary · macOS 13+_

---

## [1.0.4] — 2026-09-17

**Space Lens gets a treemap, Undo survives relaunch**

### Added & changed

- Space Lens now has two views — the sunburst it opens on, plus a new squarified treemap. Your last choice is remembered.
- Undo survives quitting the app: staging tokens persist to disk and reload at launch, and a sweep clears anything older than 30 days.
- Smart Scan counts hidden files toward folder sizes, so reported totals match what you actually reclaim. Cancelled scans no longer report inflated numbers.
- Memory Manager quits apps gracefully and asks first. Quick Free now states plainly when it skips — there is no purge without root, and it no longer pretends otherwise.
- The whole custom-drawn UI is reachable by VoiceOver, and the primary action on every screen has a keyboard shortcut.
- Rule pack grew to 21 signed rules (v1.1.0), covering caches, logs, developer artifacts, browsers, and mail.

### Fixed

- Path wildcards now match hidden entries, so dotfile caches are no longer silently skipped.
- Deletion is atomic — a partial failure rolls back instead of leaving half a batch staged.
- Rule-pack verifier pins the trusted public key and fails loudly on a bad signature.

_95 unit tests · universal binary · macOS 13+_

---

## [1.0.3] — 2026-09-01

**Free and open source**

### Added & changed

- Mac Cleaner Pro went MIT-licensed and free. No trial, no license key, no feature gate.
- Legacy pre-open-source keys keep working and show as a Supporter badge in Settings.
- Removed the checkout flow entirely — there is nothing left to buy.

### Fixed

- Fixed the broken download link and several dead donation links.
- Developer Junk no longer double-scrolls on long result lists.

_Universal binary · macOS 13+_

---

Releases before 1.0.3 predate the switch to free and open source and are not
listed here.
