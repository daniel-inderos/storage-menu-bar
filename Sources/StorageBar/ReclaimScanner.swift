import Foundation

final class ReclaimScanner {
    struct Target {
        enum AccessHint {
            case fullDiskAccess
            case filesAndFolders
        }

        let label: String
        let url: URL
        let accessHint: AccessHint
    }

    enum Result: Equatable {
        case size(Int64)
        case denied
        case missing
    }

    typealias ScanResult = (target: Target, result: Result)

    private static let cacheDuration: TimeInterval = 300

    private let fileManager: FileManager
    private let now: () -> Date
    private(set) var targets: [Target]
    private var scannedAt: Date?
    private var isScanning = false

    init(
        fileManager: FileManager = .default,
        targets: [Target]? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.now = now
        self.targets = targets ?? Self.defaultTargets(fileManager: fileManager)
    }

    func invalidateCache() {
        scannedAt = nil
    }

    func scanIfStale(
        resultHandler: @escaping (Target, Result) -> Void,
        completion: @escaping ([ScanResult]) -> Void
    ) {
        guard !isScanning else { return }
        if let scannedAt, now().timeIntervalSince(scannedAt) < Self.cacheDuration { return }

        isScanning = true
        let fileManager = fileManager
        let targets = targets
        let now = now
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var scanResults: [ScanResult] = []
            for target in targets {
                let result = Self.scan(target.url, fileManager: fileManager)
                scanResults.append((target, result))
                DispatchQueue.main.async {
                    resultHandler(target, result)
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.isScanning = false
                self?.scannedAt = now()
                completion(scanResults)
            }
        }
    }

    private static func defaultTargets(fileManager: FileManager) -> [Target] {
        var targets: [Target] = []
        if let trash = fileManager.urls(for: .trashDirectory, in: .userDomainMask).first {
            targets.append(Target(label: "Trash", url: trash, accessHint: .fullDiskAccess))
        }
        if let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            targets.append(Target(label: "Downloads", url: downloads, accessHint: .filesAndFolders))
        }
        let home = fileManager.homeDirectoryForCurrentUser
        let derivedData = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        if fileManager.fileExists(atPath: derivedData.path) {
            targets.append(Target(label: "DerivedData", url: derivedData, accessHint: .filesAndFolders))
        }
        let coreSimulator = home.appendingPathComponent("Library/Developer/CoreSimulator")
        if fileManager.fileExists(atPath: coreSimulator.path) {
            targets.append(Target(label: "CoreSimulator", url: coreSimulator, accessHint: .filesAndFolders))
        }
        let homebrewCache = home.appendingPathComponent("Library/Caches/Homebrew")
        if fileManager.fileExists(atPath: homebrewCache.path) {
            targets.append(Target(label: "Homebrew Cache", url: homebrewCache, accessHint: .filesAndFolders))
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            targets.append(Target(label: "Caches", url: caches, accessHint: .filesAndFolders))
        }
        return targets
    }

    private static func scan(_ url: URL, fileManager: FileManager) -> Result {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return .missing }
        guard let size = SystemStats.directorySize(url) else { return .denied }
        return .size(size)
    }
}
