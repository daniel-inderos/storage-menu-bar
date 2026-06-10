import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?

    private let volumeItem = NSMenuItem()
    private let availableItem = NSMenuItem()
    private let freeItem = NSMenuItem()
    private let usedItem = NSMenuItem()
    private let memoryItem = NSMenuItem()
    private let cpuItem = NSMenuItem()
    private let uptimeItem = NSMenuItem()
    private let batteryItem = NSMenuItem()
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Storage")
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        }

        buildMenu()
        statusItem.menu = menu
        menu.delegate = self

        // Prime the CPU tick baseline so the first real refresh has a delta.
        _ = SystemStats.cpuUsage()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 5

        // Hidden flag used by tooling: opens the menu, captures it to a PNG, and exits.
        // Capturing our own window doesn't require screen recording permission.
        let args = ProcessInfo.processInfo.arguments
        if let flagIndex = args.firstIndex(of: "--screenshot-menu"), flagIndex + 1 < args.count {
            let path = args[flagIndex + 1]
            // Menu tracking blocks the main run loop in event-tracking mode, so the
            // capture timer must run in .common modes to fire while the menu is open.
            let captureTimer = Timer(timeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.captureMenuScreenshot(to: path)
            }
            RunLoop.main.add(captureTimer, forMode: .common)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.statusItem.button?.performClick(nil)
            }
        }
    }

    private func captureMenuScreenshot(to path: String) {
        guard let menuWindow = NSApp.windows
            .filter({ $0 !== statusItem.button?.window && $0.frame.height > 50 })
            .max(by: { $0.frame.height < $1.frame.height })
        else { exit(2) }

        var image: NSImage?
        if let cgImage = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(menuWindow.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ) {
            image = NSImage(cgImage: cgImage, size: .zero)
        } else if let view = menuWindow.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let rendered = NSImage(size: view.bounds.size)
            rendered.addRepresentation(rep)
            image = rendered
        }

        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { exit(3) }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            exit(0)
        } catch {
            exit(4)
        }
    }

    private func buildMenu() {
        menu.autoenablesItems = false

        volumeItem.attributedTitle = NSAttributedString(
            string: "Storage",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        for item in [volumeItem, availableItem, freeItem, usedItem] {
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        for item in [memoryItem, cpuItem, uptimeItem, batteryItem] {
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let storageSettings = NSMenuItem(title: "Open Storage Settings…", action: #selector(openStorageSettings), keyEquivalent: "")
        storageSettings.target = self
        menu.addItem(storageSettings)

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit StorageBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    // MARK: Refresh

    private func refresh() {
        if let disk = SystemStats.disk() {
            statusItem.button?.title = " " + SystemStats.formatBytesShort(disk.available)

            volumeItem.attributedTitle = NSAttributedString(
                string: disk.volumeName,
                attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
            )
            availableItem.title = "Available: \(SystemStats.formatBytes(disk.available)) of \(SystemStats.formatBytes(disk.total))"
            if disk.purgeable > 1_000_000_000 {
                freeItem.title = "Free now: \(SystemStats.formatBytes(disk.free)) (+\(SystemStats.formatBytes(disk.purgeable)) purgeable)"
                freeItem.isHidden = false
            } else {
                freeItem.isHidden = true
            }
            usedItem.title = String(format: "Used: %@ — %.0f%%", SystemStats.formatBytes(disk.used), disk.usedFraction * 100)
        } else {
            statusItem.button?.title = " –"
        }

        if let mem = SystemStats.memory() {
            memoryItem.title = "Memory: \(SystemStats.formatBytes(Int64(mem.used))) of \(SystemStats.formatBytes(Int64(mem.total))) used"
        }

        var cpuParts: [String] = []
        if let cpu = SystemStats.cpuUsage() { cpuParts.append(String(format: "%.0f%%", cpu)) }
        if let load = SystemStats.loadAverage() { cpuParts.append(String(format: "load %.2f", load)) }
        cpuItem.title = "CPU: " + (cpuParts.isEmpty ? "–" : cpuParts.joined(separator: "  ·  "))

        uptimeItem.title = "Uptime: \(SystemStats.uptime())"

        if let battery = SystemStats.battery() {
            batteryItem.title = "Battery: \(battery.percent)%\(battery.charging ? " — charging" : "")"
            batteryItem.isHidden = false
        } else {
            batteryItem.isHidden = true
        }

        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    // MARK: Actions

    @objc private func refreshClicked() {
        refresh()
    }

    @objc private func openStorageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nNote: this only works when running from StorageBar.app (use build-app.sh), not from a bare `swift run` binary."
            alert.runModal()
        }
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }
}
