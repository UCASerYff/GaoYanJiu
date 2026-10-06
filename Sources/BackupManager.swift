import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - BackupService：每日备份校验、便携备份导出/恢复、恢复前安全备份
//
// 独立于 PaperStore 的备份服务。所有需要上行到 PaperStore 的动作
// （backupMessage / lastError / save / load / libraryLoadFailed 查询）
// 都通过注入的回调单向完成。迁移备份由 LibraryRepository 负责。

private struct BackupManifest: Codable {
    let product: String
    let appVersion: String
    let libraryVersion: Int
    let createdAt: Date
}

private enum BackupError: LocalizedError {
    case missingLibrary
    case unsupportedVersion(Int)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingLibrary:
            AppLocalization.text("备份中没有找到有效的资料库。")
        case let .unsupportedVersion(version):
            AppLocalization.format("备份数据版本 %d 高于当前应用支持的版本。", version)
        case let .commandFailed(message):
            message
        }
    }
}

@MainActor
final class BackupService {
    /// backupMessage 上行回调。
    var messageHandler: (String) -> Void = { _ in }
    /// lastError 上行回调。
    var errorHandler: (String) -> Void = { _ in }
    /// 导出前先落盘（PaperStore.save）。
    var persist: () -> Void = {}
    /// 恢复完成后重载（PaperStore.load）。
    var reload: () -> Void = {}
    /// 资料库加载失败查询（失败时不做自动备份）。
    var libraryLoadFailedProvider: () -> Bool = { false }

    private let decoder: JSONDecoder

    init() {
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    static let automaticBackupsURL = LibraryPaths.automaticBackups

    func exportFullBackup() {
        let panel = NSSavePanel()
        panel.title = AppLocalization.text("导出完整备份")
        panel.nameFieldStringValue = "搞研究-full-backup-\(LibraryPaths.dayFormatter.string(from: Date())).gaoyanjiu"
        panel.allowedContentTypes = [UTType(filenameExtension: "gaoyanjiu") ?? .archive]
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        let url = selectedURL.pathExtension.lowercased() == "gaoyanjiu"
            ? selectedURL
            : selectedURL.appendingPathExtension("gaoyanjiu")
        do {
            persist()
            try createPortableBackup(at: url)
            messageHandler(AppLocalization.text("完整备份已导出，记录、附件和资料文件均已包含。"))
        } catch {
            errorHandler(AppLocalization.format("备份导出失败：%@", error.localizedDescription))
        }
    }

    func chooseAndRestoreFullBackup() {
        let panel = NSOpenPanel()
        panel.title = AppLocalization.text("选择搞研究完整备份")
        panel.allowedContentTypes = [UTType(filenameExtension: "gaoyanjiu") ?? .archive]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try restorePortableBackup(from: url)
            messageHandler(AppLocalization.text("完整备份已恢复，记录和附件已经重新载入。"))
        } catch {
            errorHandler(AppLocalization.format("备份恢复失败：%@", error.localizedDescription))
        }
    }

    func createPortableBackup(at destination: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: LibraryPaths.library.path) else { throw BackupError.missingLibrary }

        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("GaoResearchBackup-\(UUID().uuidString)", isDirectory: true)
        let payload = temporaryRoot.appendingPathComponent("GaoResearchBackup", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)

        let dataDestination = payload.appendingPathComponent("AcademicAchievementManager", isDirectory: true)
        try fileManager.copyItem(at: LibraryPaths.applicationSupport, to: dataDestination)

        let manifest = BackupManifest(
            product: "搞研究",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.7",
            libraryVersion: LibrarySchema.currentVersion,
            createdAt: Date()
        )
        let manifestEncoder = JSONEncoder()
        manifestEncoder.dateEncodingStrategy = .iso8601
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try manifestEncoder.encode(manifest).write(
            to: payload.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        // 先压缩到目标旁的临时文件，成功后再替换目标；中途失败时清理临时文件且保留旧备份。
        let temporaryDestination = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporaryDestination) }
        try runDitto(arguments: ["-c", "-k", "--sequesterRsrc", payload.path, temporaryDestination.path])
        if fileManager.fileExists(atPath: destination.path) {
            do {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryDestination)
            } catch {
                // 退化为 remove + move：此时新备份已完整生成，
                // 同目录 moveItem 为原子改名，旧备份仅在改名前的瞬间缺失。
                try fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: temporaryDestination, to: destination)
            }
        } else {
            try fileManager.moveItem(at: temporaryDestination, to: destination)
        }
    }

    func restorePortableBackup(from archive: URL) throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("GaoResearchRestore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try runDitto(arguments: ["-x", "-k", archive.path, temporaryRoot.path])

        guard let libraryURL = findLibrary(in: temporaryRoot) else { throw BackupError.missingLibrary }
        let data = try Data(contentsOf: libraryURL)
        let library = try decoder.decode(PersistedLibrary.self, from: data)
        guard library.version <= LibrarySchema.currentVersion else {
            throw BackupError.unsupportedVersion(library.version)
        }

        let sourceDirectory = libraryURL.deletingLastPathComponent()
        try createPreRestoreSafetyBackup()

        let parent = LibraryPaths.applicationSupport.deletingLastPathComponent()
        let ready = parent.appendingPathComponent("AcademicAchievementManager-RestoreReady-\(UUID().uuidString)", isDirectory: true)
        let rollback = parent.appendingPathComponent("AcademicAchievementManager-RestoreRollback-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: ready)
            try? fileManager.removeItem(at: rollback)
        }
        try fileManager.copyItem(at: sourceDirectory, to: ready)
        do {
            if fileManager.fileExists(atPath: LibraryPaths.applicationSupport.path) {
                try fileManager.moveItem(at: LibraryPaths.applicationSupport, to: rollback)
            }
            try fileManager.moveItem(at: ready, to: LibraryPaths.applicationSupport)
            reload()
        } catch {
            if fileManager.fileExists(atPath: LibraryPaths.applicationSupport.path) {
                try? fileManager.removeItem(at: LibraryPaths.applicationSupport)
            }
            if fileManager.fileExists(atPath: rollback.path) {
                try? fileManager.moveItem(at: rollback, to: LibraryPaths.applicationSupport)
            }
            reload()
            throw error
        }
    }

    func createDailyAutomaticBackupIfNeeded() {
        // 资料库加载失败时不做自动备份（此时内存为空库，备份只会固化损坏状态）。
        guard !libraryLoadFailedProvider() else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: LibraryPaths.library.path) else { return }
        // 备份前先验证 library.json 可解码，避免把损坏状态备份进轮换、挤掉完好的历史备份。
        do {
            let data = try Data(contentsOf: LibraryPaths.library)
            _ = try decoder.decode(PersistedLibrary.self, from: data)
        } catch {
            messageHandler(AppLocalization.language == .english
                ? "Today’s automatic backup was skipped: the current library file cannot be read (\(error.localizedDescription)). Restore a backup first so the corrupted state does not replace a valid backup."
                : "已跳过今日自动备份：当前资料库文件无法读取（\(error.localizedDescription)）。请先恢复备份，以免损坏状态覆盖有效备份。")
            return
        }
        do {
            try fileManager.createDirectory(at: Self.automaticBackupsURL, withIntermediateDirectories: true)
            let destination = Self.automaticBackupsURL
                .appendingPathComponent("搞研究-auto-\(LibraryPaths.dayFormatter.string(from: Date())).gaoyanjiu")
            if !fileManager.fileExists(atPath: destination.path) {
                try createPortableBackup(at: destination)
            }
            try pruneAutomaticBackups(keeping: 7)
        } catch {
            messageHandler(AppLocalization.format("自动备份暂未完成：%@", error.localizedDescription))
        }
    }

    private func createPreRestoreSafetyBackup() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: LibraryPaths.library.path) else { return }
        try fileManager.createDirectory(at: LibraryPaths.migrationBackups, withIntermediateDirectories: true)
        let name = "V4.1-before-restore-\(LibraryPaths.migrationTimestampFormatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
        try fileManager.copyItem(
            at: LibraryPaths.applicationSupport,
            to: LibraryPaths.migrationBackups.appendingPathComponent(name, isDirectory: true)
        )
        MigrationBackupHousekeeping.prune(keeping: 5)
    }

    /// 每日自动备份治理：保留最近 limit 份，且总容量不超过 2GB；
    /// 超限按修改时间删最旧。最新一份无论多大都保留，避免清理后无备份可用。
    private func pruneAutomaticBackups(keeping limit: Int) throws {
        let fileManager = FileManager.default
        let files = try fileManager.contentsOfDirectory(
            at: Self.automaticBackupsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        let backups = files.filter { $0.pathExtension.lowercased() == "gaoyanjiu" }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        let sizeCap: Int64 = 2 * 1024 * 1024 * 1024
        var retainedTotal: Int64 = 0
        for (index, url) in backups.enumerated() {
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let overCount = index >= max(1, limit)
            let overCap = index > 0 && retainedTotal + size > sizeCap
            if overCount || overCap {
                try fileManager.removeItem(at: url)
                NSLog("Automatic backup pruned (%@): %@",
                      overCount ? "超过保留份数 \(limit)" : "超过总容量上限 2GB",
                      url.lastPathComponent)
            } else {
                retainedTotal += size
            }
        }
    }

    private func findLibrary(in root: URL) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "library.json" {
            return url
        }
        return nil
    }

    private func runDitto(arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackupError.commandFailed(message?.isEmpty == false ? message! : AppLocalization.text("系统压缩工具执行失败。"))
        }
    }
}

// MARK: - PaperStore 转发扩展

@MainActor
extension PaperStore {
    static let automaticBackupsURL = BackupService.automaticBackupsURL

    func exportBackup() {
        backupService.exportFullBackup()
    }

    func exportFullBackup() {
        backupService.exportFullBackup()
    }

    func chooseAndRestoreFullBackup() {
        backupService.chooseAndRestoreFullBackup()
    }

    func createPortableBackup(at destination: URL) throws {
        try backupService.createPortableBackup(at: destination)
    }

    func restorePortableBackup(from archive: URL) throws {
        try backupService.restorePortableBackup(from: archive)
    }

    func createDailyAutomaticBackupIfNeeded() {
        backupService.createDailyAutomaticBackupIfNeeded()
    }
}
