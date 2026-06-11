import AppKit
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?

    // Storage section
    private let volumeItem = NSMenuItem()
    private let availableItem = NSMenuItem()
    private let freeItem = NSMenuItem()
    private let usedItem = NSMenuItem()
    private let volumesItem = NSMenuItem(title: "Volumes", action: nil, keyEquivalent: "")
    private let volumesMenu = NSMenu()

    // System section
    private let systemHeaderItem = NSMenuItem()
    private let memoryItem = NSMenuItem()
    private let cpuItem = NSMenuItem()
    private let uptimeItem = NSMenuItem()

    // Battery section
    private let batterySeparator = NSMenuItem.separator()
    private let batteryHeaderItem = NSMenuItem()
    private let chargeItem = NSMenuItem()
    private let powerItem = NSMenuItem()
    private let healthItem = NSMenuItem()

    // Reclaim Space submenu
    private let reclaimMenu = NSMenu()
    private lazy var reclaimScanner = ReclaimScanner()
    private var reclaimRows: [(target: ReclaimScanner.Target, item: NSMenuItem)] = []
    private let grantAccessSeparator = NSMenuItem.separator()
    private let grantAccessItem = NSMenuItem(title: "Grant Full Disk Access…", action: #selector(openFullDiskAccess), keyEquivalent: "")

    // Settings submenu
    private let settingsMenu = NSMenu()
    private var displayItems: [NSMenuItem] = []
    private var intervalItems: [NSMenuItem] = []
    private var warnItems: [NSMenuItem] = []
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    private var lowSpaceNotified = false

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
        startTimer()

        // Hidden flag used by tooling: opens the menu, captures it to a PNG, and exits.
        // Capturing our own window doesn't require screen recording permission.
        let args = ProcessInfo.processInfo.arguments
        if let flagIndex = args.firstIndex(of: "--screenshot-menu"), flagIndex + 1 < args.count {
            let path = args[flagIndex + 1]
            // Menu tracking blocks the main run loop in event-tracking mode, so the
            // capture timer must run in .common modes to fire while the menu is open.
            let captureTimer = Timer(timeInterval: 4.0, repeats: false) { [weak self] _ in
                self?.captureMenuScreenshot(to: path)
            }
            RunLoop.main.add(captureTimer, forMode: .common)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.statusItem.button?.performClick(nil)
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Prefs.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = Prefs.refreshInterval / 6
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

    // MARK: Menu construction

    private func buildMenu() {
        menu.autoenablesItems = false

        volumeItem.attributedTitle = headerTitle("Storage")
        volumesItem.submenu = volumesMenu
        volumesItem.isHidden = true
        volumesMenu.autoenablesItems = false
        for item in [volumeItem, availableItem, freeItem, usedItem, volumesItem] {
            menu.addItem(item)
        }

        menu.addItem(.separator())
        systemHeaderItem.attributedTitle = headerTitle("System")
        for item in [systemHeaderItem, memoryItem, cpuItem, uptimeItem] {
            menu.addItem(item)
        }

        menu.addItem(batterySeparator)
        batteryHeaderItem.attributedTitle = headerTitle("Battery")
        for item in [batteryHeaderItem, chargeItem, powerItem, healthItem] {
            menu.addItem(item)
        }

        menu.addItem(.separator())
        buildReclaimMenu()
        let reclaimItem = NSMenuItem(title: "Reclaim Space", action: nil, keyEquivalent: "")
        reclaimItem.submenu = reclaimMenu
        menu.addItem(reclaimItem)

        buildSettingsMenu()
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit StorageBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    private func buildReclaimMenu() {
        reclaimMenu.autoenablesItems = false
        reclaimMenu.delegate = self

        let storageSettings = NSMenuItem(title: "Open Storage Settings…", action: #selector(openStorageSettings), keyEquivalent: "")
        storageSettings.target = self
        reclaimMenu.addItem(storageSettings)
        reclaimMenu.addItem(.separator())

        for target in reclaimScanner.targets {
            let item = NSMenuItem(title: target.label, action: #selector(revealTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.url
            item.attributedTitle = infoTitle(target.label, "…")
            item.toolTip = "Show in Finder"
            reclaimMenu.addItem(item)
            reclaimRows.append((target, item))
        }

        grantAccessItem.target = self
        grantAccessItem.toolTip = "Opens System Settings → Privacy & Security → Full Disk Access. "
            + "Add StorageBar there so it can size protected folders like the Trash."
        for item in [grantAccessSeparator, grantAccessItem] {
            item.isHidden = true
            reclaimMenu.addItem(item)
        }
    }

    private func buildSettingsMenu() {
        settingsMenu.autoenablesItems = false

        func addHeader(_ text: String) {
            let item = NSMenuItem()
            item.attributedTitle = headerTitle(text)
            settingsMenu.addItem(item)
        }
        func addChoice(_ title: String, _ action: Selector, _ value: Any) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.indentationLevel = 1
            settingsMenu.addItem(item)
            return item
        }

        addHeader("Menu Bar Shows")
        for display in MenuBarDisplay.allCases {
            displayItems.append(addChoice(display.label, #selector(selectDisplay(_:)), display.rawValue))
        }

        settingsMenu.addItem(.separator())
        addHeader("Refresh Every")
        for (label, seconds) in [("10 seconds", 10.0), ("30 seconds", 30.0), ("1 minute", 60.0), ("5 minutes", 300.0)] {
            intervalItems.append(addChoice(label, #selector(selectInterval(_:)), seconds))
        }

        settingsMenu.addItem(.separator())
        addHeader("Warn Below")
        for (label, gb) in [("Off", 0), ("10 GB", 10), ("25 GB", 25), ("50 GB", 50), ("100 GB", 100)] {
            warnItems.append(addChoice(label, #selector(selectWarnThreshold(_:)), gb))
        }

        settingsMenu.addItem(.separator())
        loginItem.target = self
        settingsMenu.addItem(loginItem)

        let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        settingsMenu.addItem(updatesItem)

        updateSettingsChecks()
    }

    private func updateSettingsChecks() {
        for item in displayItems {
            item.state = (item.representedObject as? String == Prefs.display.rawValue) ? .on : .off
        }
        for item in intervalItems {
            item.state = (item.representedObject as? TimeInterval == Prefs.refreshInterval) ? .on : .off
        }
        for item in warnItems {
            item.state = (item.representedObject as? Int == Prefs.warnBelowGB) ? .on : .off
        }
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    // MARK: Refresh

    private func refresh() {
        if let disk = SystemStats.disk() {
            updateStatusButton(with: disk)
            checkLowSpace(disk)

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

        refreshVolumes()

        if let mem = SystemStats.memory() {
            memoryItem.attributedTitle = infoTitle("Memory", "\(SystemStats.formatBytes(Int64(mem.used))) of \(SystemStats.formatBytes(Int64(mem.total))) used")
        }

        var cpuParts: [String] = []
        if let cpu = SystemStats.cpuUsage() { cpuParts.append(String(format: "%.0f%%", cpu)) }
        if let load = SystemStats.loadAverage() { cpuParts.append(String(format: "load %.2f", load)) }
        cpuItem.attributedTitle = infoTitle("CPU", cpuParts.isEmpty ? "–" : cpuParts.joined(separator: " · "))

        uptimeItem.attributedTitle = infoTitle("Uptime", SystemStats.uptime())

        refreshBattery()
        updateSettingsChecks()
    }

    private func updateStatusButton(with disk: DiskInfo) {
        guard let button = statusItem.button else { return }
        switch Prefs.display {
        case .freeSpace:
            button.title = " " + SystemStats.formatBytesShort(disk.available)
        case .usedPercent:
            button.title = String(format: " %.0f%%", disk.usedFraction * 100)
        case .iconOnly:
            button.title = ""
        }

        let availableGB = Double(disk.available) / 1_000_000_000
        let warnGB = Double(Prefs.warnBelowGB)
        if warnGB > 0 && availableGB < warnGB / 2 {
            button.contentTintColor = .systemRed
        } else if warnGB > 0 && availableGB < warnGB {
            button.contentTintColor = .systemOrange
        } else {
            button.contentTintColor = nil
        }
    }

    private func checkLowSpace(_ disk: DiskInfo) {
        let warnGB = Double(Prefs.warnBelowGB)
        guard warnGB > 0 else {
            lowSpaceNotified = false
            return
        }
        let availableGB = Double(disk.available) / 1_000_000_000
        if availableGB < warnGB {
            if !lowSpaceNotified {
                lowSpaceNotified = true
                postLowSpaceNotification(disk)
            }
        } else if availableGB > warnGB * 1.1 {
            // Hysteresis: re-arm only once comfortably back above the threshold.
            lowSpaceNotified = false
        }
    }

    private func postLowSpaceNotification(_ disk: DiskInfo) {
        // UNUserNotificationCenter requires an app bundle (not a bare `swift run` binary).
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Low Disk Space"
            content.body = "\(disk.volumeName) has \(SystemStats.formatBytes(disk.available)) available."
            center.add(UNNotificationRequest(identifier: "low-disk-space", content: content, trigger: nil))
        }
    }

    private func refreshVolumes() {
        let volumes = SystemStats.otherVolumes()
        volumesItem.isHidden = volumes.isEmpty
        volumesMenu.removeAllItems()
        for volume in volumes {
            let item = NSMenuItem(title: volume.name, action: #selector(revealTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = volume.url
            item.attributedTitle = infoTitle(volume.name, "\(SystemStats.formatBytesShort(volume.available)) free of \(SystemStats.formatBytesShort(volume.total))")
            item.toolTip = "Show in Finder"
            volumesMenu.addItem(item)
        }
    }

    private func refreshBattery() {
        guard let battery = SystemStats.battery() else {
            for item in [batterySeparator, batteryHeaderItem, chargeItem, powerItem, healthItem] {
                item.isHidden = true
            }
            return
        }

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
    }

    // MARK: Reclaim Space scanning

    private func scanReclaimTargetsIfStale() {
        reclaimScanner.scanIfStale { [weak self] target, result in
            guard let self,
                  let item = reclaimRows.first(where: { $0.target.url == target.url })?.item else { return }
            switch result {
            case .size(let size):
                item.attributedTitle = infoTitle(target.label, SystemStats.formatBytes(size))
                item.toolTip = "Show in Finder"
            case .denied, .missing:
                item.attributedTitle = infoTitle(target.label, "no access")
                item.toolTip = "StorageBar can't read this folder. Click to open it in Finder."
            }
        } completion: { [weak self] results in
            let denied = results.contains { scanResult in
                switch scanResult.result {
                case .size:
                    return false
                case .denied, .missing:
                    return true
                }
            }
            self?.grantAccessSeparator.isHidden = !denied
            self?.grantAccessItem.isHidden = !denied
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu {
            refresh()
        } else if menu === reclaimMenu {
            scanReclaimTargetsIfStale()
        }
    }

    // MARK: Actions

    @objc private func refreshClicked() {
        reclaimScanner.invalidateCache()
        refresh()
    }

    @objc private func revealTarget(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkForUpdates() {
        UpdateChecker.fetchLatest { result in
            DispatchQueue.main.async { [weak self] in
                self?.showUpdateResult(result)
            }
        }
    }

    private func showUpdateResult(_ result: Result<(version: String, page: URL), Error>) {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        switch result {
        case .failure(let error):
            alert.messageText = "Couldn’t Check for Updates"
            alert.informativeText = "Error: \(error.localizedDescription)"
        case .success(let latest) where UpdateChecker.isVersion(latest.version, newerThan: current):
            alert.messageText = "Update Available"
            alert.informativeText = "StorageBar \(latest.version) is available — you have \(current)."
            alert.addButton(withTitle: "View Release")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(latest.page)
            }
            return
        case .success:
            alert.messageText = "You’re Up to Date"
            alert.informativeText = "StorageBar \(current) is the latest version."
        }
        alert.runModal()
    }

    @objc private func openStorageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let display = MenuBarDisplay(rawValue: raw) else { return }
        Prefs.display = display
        refresh()
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        Prefs.refreshInterval = seconds
        startTimer()
        updateSettingsChecks()
    }

    @objc private func selectWarnThreshold(_ sender: NSMenuItem) {
        guard let gb = sender.representedObject as? Int else { return }
        Prefs.warnBelowGB = gb
        lowSpaceNotified = false
        refresh()
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
        updateSettingsChecks()
    }
}
