import Foundation

final class ReclaimScanner {
    struct Target {
        let label: String
        let url: URL
    }

    enum Result {
        case size(Int64)
        case denied
        case missing
    }

    typealias ScanResult = (target: Target, result: Result)

    private static let cacheDuration: TimeInterval = 300

    private let fileManager: FileManager
    private(set) var targets: [Target]
    private var scannedAt: Date?
    private var isScanning = false

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        targets = Self.defaultTargets(fileManager: fileManager)
    }

    func invalidateCache() {
        scannedAt = nil
    }

    func scanIfStale(
        resultHandler: @escaping (Target, Result) -> Void,
        completion: @escaping ([ScanResult]) -> Void
    ) {
        guard !isScanning else { return }
        if let scannedAt, Date().timeIntervalSince(scannedAt) < Self.cacheDuration { return }

        isScanning = true
        let fileManager = fileManager
        let targets = targets
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
                self?.scannedAt = Date()
                completion(scanResults)
            }
        }
    }

    private static func defaultTargets(fileManager: FileManager) -> [Target] {
        var targets: [Target] = []
        if let trash = fileManager.urls(for: .trashDirectory, in: .userDomainMask).first {
            targets.append(Target(label: "Trash", url: trash))
        }
        if let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            targets.append(Target(label: "Downloads", url: downloads))
        }
        let derivedData = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        if fileManager.fileExists(atPath: derivedData.path) {
            targets.append(Target(label: "DerivedData", url: derivedData))
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            targets.append(Target(label: "Caches", url: caches))
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
