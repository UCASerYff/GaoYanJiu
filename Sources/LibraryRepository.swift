import Foundation
import Darwin
import CoreFoundation

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
        if let override = ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).deletingLastPathComponent()
                .appendingPathComponent("PaperSignal", isDirectory: true)
        }
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
    /// Legacy adapter result; callers must treat absence as unavailable, never as a new library.
    case empty
    /// 资料库来自更新版本：原位保留，调用方须阻断写盘。
    case futureVersion(Int)
    /// 无法读取：原文件原位保留，调用方须阻断写盘。
    case corrupted(quarantinedFileName: String?, error: Error)
}

enum LibraryLoadFailureReason: String {
    case missing, unreadable, corrupted, futureVersion, migrationBackupFailed
}

enum LibraryPersistenceError: LocalizedError {
    case missing, invalidStructure, backupFailed(Error), initializationNotAllowed, changedSinceRead, futureVersion(Int), readRequired
    var errorDescription: String? {
        switch self {
        case .missing: return "资料库文件缺失；请恢复原资料，不能自动新建空库。"
        case .invalidStructure: return "资料库结构不完整；原文件已原位保留。"
        case .backupFailed(let error): return "升级前安全备份失败，已暂停迁移和保存：\(error.localizedDescription)"
        case .initializationNotAllowed: return "发现既有资料或备份线索，不能创建新资料库；请恢复原资料。"
        case .changedSinceRead: return "磁盘资料库已改变，请重新读取后再保存；原文件未被覆盖。"
        case .futureVersion(let version): return "资料库版本 \(version) 高于当前应用支持的版本，原文件保持不变。"
        case .readRequired: return "资料库上次读取失败，请成功重新读取后再保存。"
        }
    }
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

    /// 加载 library.json：旧目录迁移、解码、高版本拒绝、原位保留、迁移备份、迁移链调度。
    /// `migrate` 由调用方（PaperStore）提供，按阈值对内存中的资料库做归一化改写。
    func loadLibrary(migratingWith migrate: (inout PersistedLibrary, Int) -> Void) -> LibraryLoadResult
    /// 原子写 library.json。
    func saveLibrary(_ library: PersistedLibrary) throws
}

// MARK: - 默认磁盘实现

final class DiskLibraryRepository: LibraryRepository {
    let decoder: JSONDecoder
    let encoder: JSONEncoder
    let applicationSupportURL: URL
    let legacyApplicationSupportURL: URL
    let migrationBackupsURL: URL
    private let readData: (URL) throws -> Data
    private let migrationBackup: ((Int) throws -> Void)?
    private let snapshotEvidenceURLs: [URL]?
    private var lastReadData: Data?
    private var observedExistingLibrary = false
    private var writeBlockedByLoadFailure = false

    init(applicationSupportURL: URL = LibraryPaths.applicationSupport,
         legacyApplicationSupportURL: URL = LibraryPaths.legacyApplicationSupport,
         migrationBackupsURL: URL = LibraryPaths.migrationBackups,
         readData: @escaping (URL) throws -> Data = { try GaoActionFileAccess.readPrivateData(at: $0, maximumBytes: 128 * 1_048_576) },
         migrationBackup: ((Int) throws -> Void)? = nil,
         snapshotEvidenceURLs: [URL]? = nil) {
        self.applicationSupportURL = applicationSupportURL
        self.legacyApplicationSupportURL = legacyApplicationSupportURL
        self.migrationBackupsURL = migrationBackupsURL
        self.readData = readData
        self.migrationBackup = migrationBackup
        if let snapshotEvidenceURLs { self.snapshotEvidenceURLs = snapshotEvidenceURLs }
        else if ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"] != nil {
            // An isolated data-root override must never query the user's real App Group.
            self.snapshotEvidenceURLs = []
        } else if let snapshot = ResearchWidgetSnapshot.fileURL {
            self.snapshotEvidenceURLs = [snapshot, snapshot.deletingLastPathComponent().appendingPathComponent("statistics.last-good.json")]
        } else { self.snapshotEvidenceURLs = nil }
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // 紧凑输出：不写美化空白与键排序。解码与格式无关，旧文件兼容。
    }

    var libraryURL: URL { applicationSupportURL.appendingPathComponent("library.json") }
    var currentVersion: Int { LibrarySchema.currentVersion }
    /// V4.4 迁移链调度表，与原 PaperStore.load() 中的 if 链一一对应。
    var migrationThresholds: [Int] { [14, 18, 19, 20, 21, 22, 23, 24, 25, 29, 32] }

    func loadLibrary(migratingWith migrate: (inout PersistedLibrary, Int) -> Void) -> LibraryLoadResult {
        writeBlockedByLoadFailure = true
        do {
            let migratedLegacyDirectory = try migrateLegacyStorageIfNeeded()
            guard try pathExists(libraryURL) else { throw LibraryPersistenceError.missing }
            observedExistingLibrary = true
            let data = try readData(libraryURL)
            let version = try Self.libraryVersion(in: data)
            guard version <= currentVersion else { return .futureVersion(version) }
            try Self.validateStructure(data, version: version)
            var library = try decoder.decode(PersistedLibrary.self, from: data)
            if library.version < currentVersion {
                do {
                    if let migrationBackup { try migrationBackup(library.version) }
                    else { try createMigrationBackup(from: library.version) }
                } catch {
                    throw LibraryPersistenceError.backupFailed(error)
                }
            }

            let originalVersion = library.version
            for threshold in migrationThresholds where originalVersion < threshold {
                migrate(&library, threshold)
            }
            lastReadData = data
            writeBlockedByLoadFailure = false
            return .loaded(
                library: library,
                originalVersion: originalVersion,
                migratedLegacyDirectory: migratedLegacyDirectory,
                migrationBackupError: nil
            )
        } catch {
            if case LibraryPersistenceError.futureVersion(let version) = error { return .futureVersion(version) }
            return .corrupted(quarantinedFileName: nil, error: error)
        }
    }

    func saveLibrary(_ library: PersistedLibrary) throws {
        guard !writeBlockedByLoadFailure else { throw LibraryPersistenceError.readRequired }
        guard library.version <= currentVersion else { throw LibraryPersistenceError.futureVersion(library.version) }
        // Missing/unreadable/newer data is never an implicit request to create or replace a library.
        guard try pathExists(libraryURL) else { throw LibraryPersistenceError.missing }
        observedExistingLibrary = true
        let original = try readData(libraryURL)
        let version = try Self.libraryVersion(in: original)
        guard version <= currentVersion else { throw LibraryPersistenceError.futureVersion(version) }
        try Self.validateStructure(original, version: version)
        _ = try decoder.decode(PersistedLibrary.self, from: original)
        if let lastReadData, lastReadData != original { throw LibraryPersistenceError.changedSinceRead }
        let data = try encoder.encode(library)
        try GaoActionFileAccess.writePrivateData(data, to: libraryURL)
        lastReadData = data
        // library.json 含投稿门户等敏感信息；原子写每次都会重建文件，
        // 因此每次写盘后都重新收紧为仅本人可读写（0600）。失败不阻断保存，仅记日志。
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: libraryURL.path)
        } catch {
            NSLog("Failed to set 0600 permissions on library.json: %@", error.localizedDescription)
        }
    }

    static func libraryVersion(in data: Data) throws -> Int {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LibraryPersistenceError.invalidStructure
        }
        guard let value = object["version"] else { return 1 } // genuine versionless legacy files
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue,
              number.intValue >= 1 else { throw LibraryPersistenceError.invalidStructure }
        return number.intValue
    }

    static func validateStructure(_ data: Data, version: Int) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LibraryPersistenceError.invalidStructure
        }
        let arrays = ["papers", "portals", "existingWorks", "projects", "certificates", "fundingRecords", "documentFolders", "managedDocuments", "trashItems"]
        // Optional defaults keep old schemas readable; they must not turn {} or a truncated current library into zero records.
        guard object["papers"] is [Any] else { throw LibraryPersistenceError.invalidStructure }
        for key in arrays where object[key] != nil || version == LibrarySchema.currentVersion {
            guard object[key] is [Any] else { throw LibraryPersistenceError.invalidStructure }
        }
        if version == LibrarySchema.currentVersion || object["rewardCity"] != nil {
            guard object["rewardCity"] is [String: Any] else { throw LibraryPersistenceError.invalidStructure }
        }
    }

    private func pathExists(_ url: URL) throws -> Bool {
        var info = Darwin.stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    var canInitializeNewLibrary: Bool {
        guard !observedExistingLibrary, lastReadData == nil else { return false }
        do {
            guard try !pathExists(libraryURL) else { return false }
            guard let snapshotEvidenceURLs else { return false }
            for snapshot in snapshotEvidenceURLs where try pathExists(snapshot) { return false }
            let automatic = applicationSupportURL.deletingLastPathComponent().appendingPathComponent("AcademicAchievementManager-AutomaticBackups")
            for directory in [applicationSupportURL, legacyApplicationSupportURL, migrationBackupsURL, automatic] {
                if try pathExists(directory) {
                    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true,
                          try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else { return false }
                }
            }
            return true
        } catch { return false }
    }

    /// Called only by an explicit UI confirmation. O_EXCL is the final no-overwrite gate.
    func initializeNewLibraryAfterUserConfirmation() throws {
        guard canInitializeNewLibrary else { throw LibraryPersistenceError.initializationNotAllowed }
        try GaoActionFileAccess.ensurePrivateDirectory(at: applicationSupportURL)
        guard canInitializeNewLibrary else { throw LibraryPersistenceError.initializationNotAllowed }
        let data = try encoder.encode(PersistedLibrary(version: currentVersion))
        let parent = try openStorageDirectory()
        defer { close(parent) }
        let fd = openat(parent, "library.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var created = Darwin.stat()
        guard fstat(fd, &created) == 0 else { close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var completed = false
        defer {
            close(fd)
            if !completed {
                var current = Darwin.stat()
                if fstatat(parent, "library.json", &current, AT_SYMLINK_NOFOLLOW) == 0,
                   current.st_dev == created.st_dev, current.st_ino == created.st_ino {
                    unlinkat(parent, "library.json", 0)
                }
            }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                offset += count
            }
        }
        guard fsync(fd) == 0, fsync(parent) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        completed = true
        observedExistingLibrary = true
        lastReadData = data
        writeBlockedByLoadFailure = false
    }

    private func openStorageDirectory() throws -> Int32 {
        var components = GaoActionFileAccess.canonicalFileURL(applicationSupportURL).path.split(separator: "/").map(String.init)
        if let first = components.first, ["tmp", "var", "etc"].contains(first) { components.insert("private", at: 0) }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        do {
            for component in components {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                close(fd); fd = next
            }
            var info = Darwin.stat()
            guard fstat(fd, &info) == 0, info.st_uid == geteuid() else { throw LibraryPersistenceError.initializationNotAllowed }
            return fd
        } catch { close(fd); throw error }
    }

    @discardableResult
    private func migrateLegacyStorageIfNeeded() throws -> Bool {
        let fileManager = FileManager.default
        guard
            try !pathExists(libraryURL),
            try pathExists(legacyApplicationSupportURL.appendingPathComponent("library.json"))
        else { return false }
        guard !observedExistingLibrary else { throw LibraryPersistenceError.missing }

        // Never fill holes in an existing modern data directory with unrelated legacy contents.
        if try pathExists(applicationSupportURL),
           !(try fileManager.contentsOfDirectory(atPath: applicationSupportURL.path)).isEmpty {
            throw LibraryPersistenceError.missing
        }
        let legacyData = try readData(legacyApplicationSupportURL.appendingPathComponent("library.json"))
        let legacyVersion = try Self.libraryVersion(in: legacyData)
        guard legacyVersion <= currentVersion else { throw LibraryPersistenceError.futureVersion(legacyVersion) }
        try Self.validateStructure(legacyData, version: legacyVersion)
        _ = try decoder.decode(PersistedLibrary.self, from: legacyData)

        let automatic = applicationSupportURL.deletingLastPathComponent().appendingPathComponent("AcademicAchievementManager-AutomaticBackups")
        for backup in [migrationBackupsURL, automatic] where try pathExists(backup) {
            guard try fileManager.contentsOfDirectory(atPath: backup.path).isEmpty else { throw LibraryPersistenceError.missing }
        }
        let staging = applicationSupportURL.deletingLastPathComponent().appendingPathComponent(".ResearchLegacyMigration-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: legacyApplicationSupportURL, to: staging)
        guard try readData(staging.appendingPathComponent("library.json")) == legacyData else { throw LibraryPersistenceError.changedSinceRead }
        if try pathExists(applicationSupportURL) {
            guard try fileManager.contentsOfDirectory(atPath: applicationSupportURL.path).isEmpty else { throw LibraryPersistenceError.missing }
            try fileManager.removeItem(at: applicationSupportURL)
        }
        try fileManager.moveItem(at: staging, to: applicationSupportURL)
        return true
    }

    private func createMigrationBackup(from libraryVersion: Int) throws {
        let fileManager = FileManager.default
        guard try pathExists(libraryURL) else { throw LibraryPersistenceError.missing }

        try fileManager.createDirectory(
            at: migrationBackupsURL,
            withIntermediateDirectories: true
        )
        let sourceRelease = LibrarySchema.releaseName(forLibraryVersion: libraryVersion)
        let folderName = "\(sourceRelease)-before-\(LibrarySchema.marketingVersion)-\(LibraryPaths.migrationTimestampFormatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
        let destination = migrationBackupsURL.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.copyItem(at: applicationSupportURL, to: destination)
        if migrationBackupsURL == LibraryPaths.migrationBackups { MigrationBackupHousekeeping.prune(keeping: 5) }
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
