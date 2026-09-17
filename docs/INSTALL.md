# Installing Mac Cleaner Pro

Mac Cleaner Pro ships ad-hoc signed and **not notarized**. macOS Gatekeeper will ask you to confirm the first launch. This is a **one-time** approval — every subsequent launch opens normally.

## Step 1 — Drag to Applications

1. Open the downloaded `MacCleanerPro-<version>.dmg`.
2. Drag **Mac Cleaner Pro** onto the **Applications** folder shortcut.
3. Eject the DMG.

## Step 2 — Verify the download (optional, 5 seconds)

Every release publishes a SHA-256 hash. Because this build isn't notarized, this is how you confirm the file you downloaded is the file we built:

```sh
shasum -a 256 ~/Downloads/MacCleanerPro-<version>.dmg
```

Compare the output with the hash on the [release page](https://github.com/vunexolabs/mac-cleaner-pro/releases). If they differ, don't open it — tell us.

## Step 3 — First launch (one-time approval)

On first launch, macOS shows a dialog saying it can't verify the developer, and offers only **Done** or **Cancel**. That's Gatekeeper reporting, accurately, that this build isn't notarized — we haven't paid Apple's $99/yr developer fee yet. Approve it once:

1. Open the **Applications** folder in Finder.
2. **Right-click** (or Control-click) **Mac Cleaner Pro**.
3. Choose **Open** from the context menu.
4. Click **Open** in the confirmation dialog.

After this once, double-clicking will always work.

> **Why is this needed?** Apple requires every distributed app to be signed by a paid Developer ID and notarized through their service. Until donations cover that fee, we ship ad-hoc signed builds that work identically — Gatekeeper just adds a one-time prompt. The source is public, and every release publishes a checksum, so you don't have to take our word for what's in the build.

## Step 4 — Grant Full Disk Access

The first-run wizard will guide you through this. You'll need to:

1. Open **System Settings → Privacy & Security → Full Disk Access**.
2. Toggle **Mac Cleaner Pro** on.

Without Full Disk Access, scans will only find a fraction of what's reclaimable.

## What's currently disabled in v1.0

A few features require a privileged helper daemon, which itself requires the paid Developer ID:

- System cache cleanup (`/Library/Caches/*`)
- App leftovers in `/Library/LaunchDaemons/`, `/Library/PrivilegedHelperTools/`

These appear in the UI with a **Requires helper** badge so you know what's there. They'll light up automatically in a future release.

## Uninstalling Mac Cleaner Pro

The cleanest way: open Mac Cleaner Pro, go to **App Uninstaller**, search for "Mac Cleaner Pro", and use it to uninstall itself. Otherwise, drag `Applications/Mac Cleaner Pro.app` to the Trash and (optionally) remove `~/Library/Application Support/MacCleanerPro/` for a complete cleanup.
