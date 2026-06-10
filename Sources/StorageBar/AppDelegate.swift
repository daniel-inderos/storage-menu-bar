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
    private let systemHeaderItem = NSMenuItem()
    private let memoryItem = NSMenuItem()
    private let cpuItem = NSMenuItem()
    private let uptimeItem = NSMenuItem()
    private let batterySeparator = NSMenuItem.separator()
    private let batteryHeaderItem = NSMenuItem()
    private let chargeItem = NSMenuItem()
    private let powerItem = NSMenuItem()
    private let healthItem = NSMenuItem()
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

    // MARK: Menu text styling
    //
    // Info rows are enabled but have no action, so they read at full contrast
    // (AppKit dims disabled items, even with attributed titles) while clicking
    // them does nothing. A tab stop aligns the values into a column.

    private static let valueColumn: CGFloat = 88

    private func headerTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    private func infoTitle(_ label: String, _ value: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: Self.valueColumn)]
        paragraph.headIndent = Self.valueColumn
        let title = NSMutableAttributedString(string: label + "\t", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        title.append(NSAttributedString(string: value, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]))
        return title
    }

    private func buildMenu() {
        menu.autoenablesItems = false

        volumeItem.attributedTitle = headerTitle("Storage")
        for item in [volumeItem, availableItem, freeItem, usedItem] {
            item.isEnabled = true
            menu.addItem(item)
        }

        menu.addItem(.separator())
        systemHeaderItem.attributedTitle = headerTitle("System")
        for item in [systemHeaderItem, memoryItem, cpuItem, uptimeItem] {
            item.isEnabled = true
            menu.addItem(item)
        }

        menu.addItem(batterySeparator)
        batteryHeaderItem.attributedTitle = headerTitle("Battery")
        for item in [batteryHeaderItem, chargeItem, powerItem, healthItem] {
            item.isEnabled = true
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

            volumeItem.attributedTitle = headerTitle(disk.volumeName)
            availableItem.attributedTitle = infoTitle("Available", "\(SystemStats.formatBytes(disk.available)) of \(SystemStats.formatBytes(disk.total))")
            if disk.purgeable > 1_000_000_000 {
                freeItem.attributedTitle = infoTitle("Free now", "\(SystemStats.formatBytes(disk.free)) (+\(SystemStats.formatBytes(disk.purgeable)) purgeable)")
                freeItem.isHidden = false
            } else {
                freeItem.isHidden = true
            }
            usedItem.attributedTitle = infoTitle("Used", String(format: "%@ · %.0f%%", SystemStats.formatBytes(disk.used), disk.usedFraction * 100))
        } else {
            statusItem.button?.title = " –"
        }

        if let mem = SystemStats.memory() {
            memoryItem.attributedTitle = infoTitle("Memory", "\(SystemStats.formatBytes(Int64(mem.used))) of \(SystemStats.formatBytes(Int64(mem.total))) used")
        }

        var cpuParts: [String] = []
        if let cpu = SystemStats.cpuUsage() { cpuParts.append(String(format: "%.0f%%", cpu)) }
        if let load = SystemStats.loadAverage() { cpuParts.append(String(format: "load %.2f", load)) }
        cpuItem.attributedTitle = infoTitle("CPU", cpuParts.isEmpty ? "–" : cpuParts.joined(separator: " · "))

        uptimeItem.attributedTitle = infoTitle("Uptime", SystemStats.uptime())

        if let battery = SystemStats.battery() {
            var charge = "\(battery.percent)%"
            if battery.isCharging {
                charge += " — charging"
                if let toFull = battery.timeToFull { charge += " · \(SystemStats.formatMinutes(toFull)) to full" }
            } else if battery.onACPower {
                charge += battery.percent == 100 ? " — charged" : " — on hold"
            } else if let toEmpty = battery.timeToEmpty {
                charge += " · \(SystemStats.formatMinutes(toEmpty)) left"
            }
            chargeItem.attributedTitle = infoTitle("Charge", charge)
            powerItem.attributedTitle = infoTitle("Power", battery.onACPower ? "AC Power" : "Battery")

            var healthParts: [String] = []
            if let health = battery.healthPercent { healthParts.append("\(health)% capacity") }
            if let cycles = battery.cycleCount { healthParts.append("\(cycles) cycles") }
            healthItem.attributedTitle = infoTitle("Health", healthParts.joined(separator: " · "))
            healthItem.isHidden = healthParts.isEmpty

            for item in [batterySeparator, batteryHeaderItem, chargeItem, powerItem] {
                item.isHidden = false
            }
        } else {
            for item in [batterySeparator, batteryHeaderItem, chargeItem, powerItem, healthItem] {
                item.isHidden = true
            }
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
