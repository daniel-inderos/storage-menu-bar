# StorageBar

A tiny, dependency-free macOS menu bar app that shows your remaining disk
space at a glance — with memory, CPU, uptime, and battery info one click away.

Built with Swift + AppKit. No Xcode project, no Electron, no dependencies —
just a Swift package you can build and run in seconds.

```
┌─────────────────────────────────────┐
│  ⛁ 246 GB                          │   ← lives in your menu bar
├─────────────────────────────────────┤
│  Macintosh HD                       │
│  Available: 245.93 GB of 494.38 GB  │
│  Free now: 230.1 GB (+15.8 GB purgeable)
│  Used: 248.45 GB — 50%              │
│  ───────────────────────────────    │
│  Memory: 18.2 GB of 32 GB used      │
│  CPU: 7%  ·  load 2.31              │
│  Uptime: 3d 4h 12m                  │
│  Battery: 87% — charging            │
│  ───────────────────────────────    │
│  Open Storage Settings…             │
│  Refresh                         ⌘R │
│  Launch at Login                    │
│  ───────────────────────────────    │
│  Quit StorageBar                 ⌘Q │
└─────────────────────────────────────┘
```

## Features

- **Storage in your menu bar** — available space on your startup volume,
  measured Finder-style (includes purgeable space macOS can reclaim), with the
  truly-free vs. purgeable breakdown in the dropdown
- **Memory usage** counted the way Activity Monitor does (active + wired + compressed)
- **CPU usage** and 1-minute load average
- **Uptime** and **battery** level / charging state (battery row auto-hides on desktops)
- **Open Storage Settings…** jumps straight to macOS's storage management pane
  when it's time to free up space
- **Launch at Login** toggle built in (via `SMAppService`)
- Auto-refreshes every 30 seconds and every time you open the menu
- No Dock icon, no windows — it's a menu bar app and nothing else

## Install

Requires macOS 13+ and a Swift toolchain (Xcode or Command Line Tools).

```sh
git clone https://github.com/daniel-inderos/storage-menu-bar.git
cd storage-menu-bar
./build-app.sh
open StorageBar.app
```

To keep it around, move `StorageBar.app` to `/Applications` and enable
**Launch at Login** from its menu.

> **Note:** the build script ad-hoc signs the app. Since it isn't notarized,
> Gatekeeper may prompt the first time you launch a copy you didn't build
> yourself — building from source avoids this entirely.

## Development

```sh
swift run            # quick iteration (Launch at Login needs the .app bundle)
./build-app.sh       # release build + assemble StorageBar.app
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

## License

[MIT](LICENSE)
