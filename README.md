<p align="center">
  <img src="docs/icon.png" width="128" alt="StorageBar icon">
</p>

# StorageBar

A tiny, dependency-free macOS menu bar app that shows your remaining disk
space at a glance — with memory, CPU, uptime, and battery info one click away.

Built with Swift + AppKit. No Xcode project, no Electron, no dependencies —
just a Swift package you can build and run in seconds.

<p align="center">
  <img src="docs/menu.png" width="343" alt="StorageBar's dropdown menu showing available, free, and used disk space, memory, CPU, uptime, and battery">
</p>

## Features

- **Storage in your menu bar** — available space on your startup volume,
  measured Finder-style (includes purgeable space macOS can reclaim), with the
  truly-free vs. purgeable breakdown in the dropdown
- **Low-space warning** — the menu bar reading turns orange below a threshold
  you choose (off / 10 / 25 / 50 / 100 GB), red below half of it, and sends a
  one-time notification when you cross it
- **Other volumes** — external drives and other mounted volumes appear in a
  Volumes submenu with their free space; click one to open it in Finder
- **Reclaim Space submenu** — sizes of the usual space hogs (Trash, Downloads,
  Xcode DerivedData, CoreSimulator, Homebrew Cache, and Caches), each one
  click from Finder, plus a shortcut to macOS's Storage Settings pane. Sizes
  are computed in the background and cached for five minutes. Trash sizing
  needs Full Disk Access because macOS protects `~/.Trash`; if Downloads or
  another folder is blocked, StorageBar points you to System Settings →
  Privacy & Security → Files & Folders (Full Disk Access also works)
- **Memory usage** counted the way Activity Monitor does (active + wired + compressed)
- **CPU usage** and 1-minute load average, plus **uptime**
- **Battery section** — charge level, time remaining (or time until full when
  charging), power source, battery health, and cycle count; hides itself
  entirely on desktops
- **Settings submenu** — what the menu bar shows (free space, used percentage,
  or icon only), refresh interval, warning threshold, Launch at Login, and a
  Check for Updates that compares against the latest GitHub release.
  Everything lives in the menu; there are no windows
- No Dock icon — it's a menu bar app and nothing else

## Install

### Upgrading from 1.2.x or earlier

Your settings carry over automatically. Launch at Login and Full Disk Access
need one re-grant because the app identity changed.

### Build from source (recommended)

Requires macOS 13+ and a Swift toolchain (Xcode or Command Line Tools).
Building locally means you trust your own toolchain and the source you just
checked out, and it avoids the Gatekeeper quarantine step entirely.

```sh
git clone https://github.com/daniel-inderos/storage-menu-bar.git
cd storage-menu-bar
./build-app.sh
open StorageBar.app
```

### Homebrew

The tap is convenient for upgrades, but today it installs the same prebuilt app
as the release zip: ad-hoc signed, not Developer ID-signed, and not notarized.

```sh
HOMEBREW_CASK_OPTS=--no-quarantine brew install --cask daniel-inderos/tap/storagebar
```

`--no-quarantine` tells Homebrew not to add macOS's quarantine attribute to the
downloaded app. That bypasses Gatekeeper's first-launch block for an
unnotarized app; it is not an extra trust check. Homebrew has deprecated this
flag and plans to remove it around September 2026, along with disabling casks
that fail Gatekeeper checks.

The [tap](https://github.com/daniel-inderos/homebrew-tap) is updated
automatically by the release workflow, so `brew upgrade` picks up new versions.
Until releases are Developer ID-signed and notarized, this path is best suited
to people comfortable vetting the source and choosing that Gatekeeper tradeoff.

If you install without `--no-quarantine` and macOS blocks the first launch, you
can approve it in System Settings → Privacy & Security → "Open Anyway", or
clear quarantine yourself on any macOS version:

```sh
xattr -cr /Applications/StorageBar.app
```

### Download

Grab `StorageBar.zip` from the
[latest release](https://github.com/daniel-inderos/storage-menu-bar/releases/latest),
unzip it, and move `StorageBar.app` to `/Applications`.

The app is ad-hoc signed, not Developer ID-signed, and not notarized, so macOS
will quarantine the download. On recent macOS versions, you can approve the
blocked first launch in System Settings → Privacy & Security → "Open Anyway".
Or clear the quarantine attribute yourself on any macOS version:

```sh
xattr -cr /Applications/StorageBar.app
```

Until releases are Developer ID-signed and notarized, direct downloads are best
suited to people comfortable vetting the source before trusting the prebuilt
app.

## Development

```sh
swift run            # quick iteration (Launch at Login needs the .app bundle)
swift test           # unit tests (also run by CI on every push)
./build-app.sh       # release build + assemble StorageBar.app
```

The README screenshot is generated by the app itself (it captures its own
menu window, which needs no screen recording permission):

```sh
./.build/release/StorageBar --screenshot-menu docs/menu.png
```

## How it works

All stats come from native APIs — no shelling out, no polling daemons:

| Stat | Source |
|---|---|
| Disk space | `URLResourceValues` (`volumeAvailableCapacityForImportantUsageKey` for the Finder-style number) |
| Memory | Mach `host_statistics64` (`vm_statistics64`) |
| CPU | Mach `host_cpu_load_info` tick deltas + `getloadavg` |
| Battery | IOKit power sources (`IOPSCopyPowerSourcesInfo`) |
| Uptime | `ProcessInfo.systemUptime` |

The menu bar item is a plain AppKit `NSStatusItem`; `build-app.sh` wraps the
SwiftPM release binary into a minimal `.app` bundle with `LSUIElement` set so
it stays out of the Dock.

## Privacy & Trust

StorageBar has no telemetry, analytics, auto-update, or background daemon.
Normal use makes no network requests. The only network access is Check for
Updates, which makes one request to the GitHub releases API when you click it
and offers to open the release page if a newer version exists.

Core disk, memory, CPU, uptime, battery, and volume stats need no special
permissions. The Reclaim Space submenu sizes folders in the background:
sizing Trash needs Full Disk Access because macOS protects `~/.Trash`, and
sizing Downloads may trigger macOS's standard Files & Folders prompt.
Everything else works without those permissions.

Launch at Login uses Apple's `ServiceManagement` API only when you turn on the
menu item. The app is an `LSUIElement` menu bar app, so it has no Dock icon and
does not install a helper daemon.

Releases are ad-hoc signed by `build-app.sh` (`codesign --sign -`). Plain
English: macOS sees a signed bundle with a stable local identity, but Apple has
not verified the developer identity and has not notarized the build. That is
why prebuilt downloads can be blocked by Gatekeeper until you explicitly
approve them or remove quarantine. The app source is a handful of Swift files,
so it is practical to audit in one sitting before deciding whether to run the
prebuilt app.

## License

[MIT](LICENSE)
