import Foundation

enum AppPaths {
    /// The app isn't sandboxed, so Application Support is shared and needs a folder of its own.
    static let support = prepared(URL.applicationSupportDirectory.appending(path: "MeroTyperAI", directoryHint: .isDirectory))
    /// Models can be downloaded again, so they stay out of Time Machine backups.
    static let models = prepared(support.appending(path: "Models", directoryHint: .isDirectory), excludeFromBackup: true)
    static var history: URL { support.appending(path: "history.json") }

    private static func prepared(_ url: URL, excludeFromBackup: Bool = false) -> URL {
        var url = url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = excludeFromBackup
        try? url.setResourceValues(values)
        return url
    }

    static var freeBytes: Int64 {
        let values = try? support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func size(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys))
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
