import Foundation

// MARK: - 资料库路径与 schema 常量
//
// LibraryPaths 集中管理数据目录解析（含 GAO_RESEARCH_DATA_DIR 测试钩子）、
// 全部磁盘路径与共享日期格式器。PaperStore 上的同名静态成员原样保留并转发到这里，
// 视图层与既有测试（PaperStore.libraryURL 等）无需改动。

enum LibraryPaths {
    static let applicationSupport: URL = {
        if let override = ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("GaoSeries/Research/AcademicAchievementManager", isDirectory: true)
    }()

    static let library = applicationSupport.appendingPathComponent("library.json")
    static let attachments = applicationSupport.appendingPathComponent("Attachments", isDirectory: true)
    static let certificateAttachments = applicationSupport.appendingPathComponent("CertificateAttachments", isDirectory: true)
    static let managedDocuments = applicationSupport.appendingPathComponent("ManagedDocuments", isDirectory: true)
    static let trashStorage = applicationSupport.appendingPathComponent("TrashStorage", isDirectory: true)

    static let legacyApplicationSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PaperSignal", isDirectory: true)
    }()
    static let legacyLibrary = legacyApplicationSupport.appendingPathComponent("library.json")

    static let migrationBackups: URL = {
        if let override = ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .deletingLastPathComponent()
                .appendingPathComponent("AcademicAchievementManager-MigrationBackups", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("GaoSeries/Research/AcademicAchievementManager-MigrationBackups", isDirectory: true)
    }()

    static let automaticBackups: URL = {
        applicationSupport.deletingLastPathComponent()
            .appendingPathComponent("AcademicAchievementManager-AutomaticBackups", isDirectory: true)
    }()

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let migrationTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum LibrarySchema {
    static let currentVersion = 32

    static var marketingVersion: String {
        let full = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.7"
        let parts = full.split(separator: ".")
        guard parts.count >= 2 else { return "V\(full)" }
        return "V\(parts[0]).\(parts[1])"
    }

    static func releaseName(forLibraryVersion version: Int) -> String {
        switch version {
        case 32: "V4.6"
        case 31: "V4.1"
        case 30: "V4.0"
        case 29: "V3.9"
        case 28: "V3.8"
        case 27: "V3.7"
        case 26: "V3.6"
        case 25: "V3.5"
        case 24: "V3.4"
        case 23: "V3.3"
        case 22: "V3.2"
        case 21: "V3.1"
        case 20: "V3.0"
        case 19: "V2.6"
        case 18: "V2.5"
        case 17: "V2.4"
        case 16: "V2.3"
        case 15: "V2.2"
        case 14: "V2.1"
        case 13: "V2.0"
        case 12: "V1.4"
        case 11: "V1.3"
        case 10: "V1.2"
        case 9: "V1.1"
        case 8: "V1.0"
        case 7: "V0.9"
        default: "Legacy-v\(version)"
        }
    }
}

// MARK: - 加载结果

enum LibraryLoadResult {
    /// 成功解码（迁移链已在内存中跑完，尚未落盘）。
    case loaded(
        library: PersistedLibrary,
        originalVersion: Int,
        migratedLegacyDirectory: Bool,
        migrationBackupError: Error?
    )
    /// library.json 不存在：安全的空库。
    case empty
    /// 资料库来自更新版本：原位保留，调用方须阻断写盘。
    case futureVersion(Int)
    /// 无法解码：已尝试隔离原文件，调用方须阻断写盘。
    case corrupted(quarantinedFileName: String?, error: Error)
}

// MARK: - LibraryRepository 协议

/// 持久化边界。默认实现走磁盘（DiskLibraryRepository）；测试可注入内存替身，
/// 从而在不触碰文件系统的情况下驱动 PaperStore。
protocol LibraryRepository: AnyObject {
    var libraryURL: URL { get }
    var applicationSupportURL: URL { get }
    /// 当前应用可写的最新 schema 版本。
    var currentVersion: Int { get }
    /// 迁移链阈值序列：loaded 版本低于哪个阈值就触发对应迁移步骤。
    var migrationThresholds: [Int] { get }

    /// 加载 library.json：旧目录迁移、解码、高版本拒绝、损坏隔离、迁移备份、迁移链调度。
    /// `migrate` 由调用方（PaperStore）提供，按阈值对内存中的资料库做归一化改写。
    func loadLibrary(migratingWith migrate: (inout PersistedLibrary, Int) -> Void) -> LibraryLoadResult
    /// 原子写 library.json。
    func saveLibrary(_ library: PersistedLibrary) throws
}

// MARK: - 默认磁盘实现

final class DiskLibraryRepository: LibraryRepository {
    let decoder: JSONDecoder
    let encoder: JSONEncoder

    init() {
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // 紧凑输出：不写美化空白与键排序。解码与格式无关，旧文件兼容。
    }

    var libraryURL: URL { LibraryPaths.library }
    var applicationSupportURL: URL { LibraryPaths.applicationSupport }
    var currentVersion: Int { LibrarySchema.currentVersion }
    /// V4.4 迁移链调度表，与原 PaperStore.load() 中的 if 链一一对应。
    var migrationThresholds: [Int] { [14, 18, 19, 20, 21, 22, 23, 24, 25, 29, 32] }

    func loadLibrary(migratingWith migrate: (inout PersistedLibrary, Int) -> Void) -> LibraryLoadResult {
        do {
            let migratedLegacyDirectory = try migrateLegacyStorageIfNeeded()
            let data = try Data(contentsOf: libraryURL)
            var library = try decoder.decode(PersistedLibrary.self, from: data)

            guard library.version <= currentVersion else {
                // 资料库来自更新版本：不隔离（文件本身完好，升级后仍须原位可读）。
                return .futureVersion(library.version)
            }

            var migrationBackupError: Error?
            if library.version < currentVersion {
                do {
                    try createMigrationBackup(from: library.version)
                } catch {
                    migrationBackupError = error
                }
            }

            let originalVersion = library.version
            for threshold in migrationThresholds where originalVersion < threshold {
                migrate(&library, threshold)
            }

            return .loaded(
                library: library,
                originalVersion: originalVersion,
                migratedLegacyDirectory: migratedLegacyDirectory,
                migrationBackupError: migrationBackupError
            )
        } catch CocoaError.fileReadNoSuchFile {
            return .empty
        } catch {
            let quarantinedFileName = quarantineCorruptedLibraryFile()
            return .corrupted(quarantinedFileName: quarantinedFileName, error: error)
        }
    }

    func saveLibrary(_ library: PersistedLibrary) throws {
        try FileManager.default.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(library)
        try data.write(to: libraryURL, options: .atomic)
        // library.json 含投稿门户等敏感信息；原子写每次都会重建文件，
        // 因此每次写盘后都重新收紧为仅本人可读写（0600）。失败不阻断保存，仅记日志。
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: libraryURL.path)
        } catch {
            NSLog("Failed to set 0600 permissions on library.json: %@", error.localizedDescription)
        }
    }

    /// 将无法解码的资料库文件改名隔离保留，避免后续流程误读；改名失败不致命，只记录日志。
    private func quarantineCorruptedLibraryFile() -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: libraryURL.path) else { return nil }
        let name = "library.corrupted-\(LibraryPaths.migrationTimestampFormatter.string(from: Date())).json"
        do {
            try fileManager.moveItem(
                at: libraryURL,
                to: applicationSupportURL.appendingPathComponent(name)
            )
            return name
        } catch {
            NSLog("Failed to quarantine corrupted library file: %@", error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    private func migrateLegacyStorageIfNeeded() throws -> Bool {
        let fileManager = FileManager.default
        guard
            !fileManager.fileExists(atPath: libraryURL.path),
            fileManager.fileExists(atPath: LibraryPaths.legacyLibrary.path)
        else { return false }

        try fileManager.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: true
        )
        let legacyItems = try fileManager.contentsOfDirectory(
            at: LibraryPaths.legacyApplicationSupport,
            includingPropertiesForKeys: nil
        )
        for source in legacyItems {
            let destination = applicationSupportURL.appendingPathComponent(source.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.copyItem(at: source, to: destination)
        }
        return true
    }

    private func createMigrationBackup(from libraryVersion: Int) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: libraryURL.path) else { return }

        try fileManager.createDirectory(
            at: LibraryPaths.migrationBackups,
            withIntermediateDirectories: true
        )
        let sourceRelease = LibrarySchema.releaseName(forLibraryVersion: libraryVersion)
        let folderName = "\(sourceRelease)-before-\(LibrarySchema.marketingVersion)-\(LibraryPaths.migrationTimestampFormatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
        let destination = LibraryPaths.migrationBackups.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.copyItem(at: applicationSupportURL, to: destination)
        MigrationBackupHousekeeping.prune(keeping: 5)
    }
}

// MARK: - 迁移/恢复前备份目录容量治理

/// MigrationBackups 目录保留策略：按修改时间保留最近若干份，多余的删最旧。
/// 只清理备份目录本身，用户数据本体绝不动。
enum MigrationBackupHousekeeping {
    static func prune(keeping limit: Int = 5) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: LibraryPaths.migrationBackups,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let sorted = entries.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for url in sorted.dropFirst(max(1, limit)) {
            do {
                try fileManager.removeItem(at: url)
                NSLog("Migration backup pruned (keep %d): %@", limit, url.lastPathComponent)
            } catch {
                NSLog("Failed to prune migration backup %@: %@", url.lastPathComponent, error.localizedDescription)
            }
        }
    }
}
