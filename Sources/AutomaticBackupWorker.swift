import CryptoKit
import Darwin
import Foundation

/// File work only. Never runs on the main actor and never rewrites the live library.
/// A concurrent edit invalidates this attempt instead of publishing a mixed backup.
enum AutomaticBackupWorker {
    struct Plan {
        let source: URL
        let destination: URL
        let appVersion: String
        let libraryVersion: Int
    }
    enum Outcome: String { case created, alreadyExistsNotRevalidated }
    enum Failure: LocalizedError {
        case unsafePath, changedDuringSnapshot, invalidLibrary, missingDeclaredAttachment, commandFailed
        var errorDescription: String? {
            switch self {
            case .unsafePath: return "备份路径包含不支持的文件类型或链接，已保留既有备份。"
            case .changedDuringSnapshot: return "资料在备份期间发生变化，未发布不一致副本；既有备份保持不变。"
            case .invalidLibrary: return "资料库版本无法验证，未生成新备份。"
            case .missingDeclaredAttachment: return "资料库声明的附件缺失或不符，未生成不完整备份；原资料及既有备份已保留。"
            case .commandFailed: return "系统压缩或完整性检查未成功，未生成新备份。"
            }
        }
    }
    struct Entry: Equatable {
        let kind: String
        let bytes: Int64
        let digest: String?
    }

    static func run(_ plan: Plan, afterCopy: (() throws -> Void)? = nil) throws -> Outcome {
        precondition(!Thread.isMainThread, "Automatic backup disk work must not block the main thread")
        let fm = FileManager.default
        let parent = plan.destination.deletingLastPathComponent()
        // Reopening on the same day does not reread every attachment or reencode the library.
        if try exists(plan.destination) {
            var info = stat()
            guard lstat(plan.destination.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { throw Failure.unsafePath }
            return .alreadyExistsNotRevalidated
        }
        let temporary = fm.temporaryDirectory.appendingPathComponent("ResearchAutomaticBackup-\(UUID().uuidString).noindex", isDirectory: true)
        let payload = temporary.appendingPathComponent("GaoResearchBackup", isDirectory: true)
        let copied = payload.appendingPathComponent("AcademicAchievementManager", isDirectory: true)
        let archive = parent.appendingPathComponent(".\(plan.destination.lastPathComponent).partial-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary); try? fm.removeItem(at: archive) }
        try fm.createDirectory(at: payload, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let before = try inventory(plan.source)
        try validateLibrary(plan.source.appendingPathComponent("library.json"), expectedVersion: plan.libraryVersion, inventory: before)
        try fm.copyItem(at: plan.source, to: copied)
        try afterCopy?()
        // Both the copied payload and the live source must still match the full initial manifest.
        // Missing, unreadable, symlink and special entries are errors, never absent/default data.
        guard try inventory(copied) == before, try inventory(plan.source) == before else { throw Failure.changedDuringSnapshot }
        try validateLibrary(copied.appendingPathComponent("library.json"), expectedVersion: plan.libraryVersion, inventory: before)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Manifest: Codable {
            let product: String; let appVersion: String; let libraryVersion: Int; let createdAt: Date
            let files: [String: String]
        }
        let files = before.compactMapValues(\.digest)
        try encoder.encode(Manifest(product: "搞研究", appVersion: plan.appVersion,
                                    libraryVersion: plan.libraryVersion, createdAt: Date(), files: files))
            .write(to: payload.appendingPathComponent("manifest.json"), options: .atomic)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try command("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", payload.path, archive.path])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        try command("/usr/bin/unzip", ["-tqq", archive.path])
        // Do not advertise the day as backed up if writes happened while compression ran.
        guard try inventory(plan.source) == before else { throw Failure.changedDuringSnapshot }
        try syncFile(archive)
        // Exclusive, same-directory publication: an existing daily backup is never replaced.
        if renamex_np(archive.path, plan.destination.path, UInt32(RENAME_EXCL)) != 0 {
            if errno == EEXIST { return .alreadyExistsNotRevalidated }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try syncDirectory(parent)
        return .created
    }

    static func inventory(_ root: URL) throws -> [String: Entry] {
        let fm = FileManager.default
        var result: [String: Entry] = [:]
        func visit(_ url: URL, relative: String) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                result[relative] = Entry(kind: "directory", bytes: 0, digest: nil)
                for name in try fm.contentsOfDirectory(atPath: url.path).sorted() {
                    try visit(url.appendingPathComponent(name), relative: relative.isEmpty ? name : relative + "/" + name)
                }
            case S_IFREG:
                let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                defer { close(fd) }
                var opened = stat(); guard fstat(fd, &opened) == 0,
                    opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else { throw Failure.changedDuringSnapshot }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                var digest = SHA256(); var count: Int64 = 0
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data); count += Int64(data.count) }
                var end = stat(); guard fstat(fd, &end) == 0, count == info.st_size,
                    end.st_size == info.st_size, end.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                    end.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
                    end.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
                    end.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else { throw Failure.changedDuringSnapshot }
                result[relative] = Entry(kind: "file", bytes: count, digest: digest.finalize().map { String(format: "%02x", $0) }.joined())
            default: throw Failure.unsafePath
            }
        }
        try visit(root, relative: "")
        return result
    }

    private static func validateLibrary(_ url: URL, expectedVersion: Int, inventory: [String: Entry]) throws {
        let data = try GaoActionFileAccess.readPrivateData(at: url, maximumBytes: 128 * 1_048_576)
        let version = try DiskLibraryRepository.libraryVersion(in: data)
        guard version <= expectedVersion else { throw Failure.invalidLibrary }
        try DiskLibraryRepository.validateStructure(data, version: version)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let library = try decoder.decode(PersistedLibrary.self, from: data)
        try validateDeclaredAttachments(library, inventory: inventory)
    }
    /// A snapshot of the files which happen to exist is insufficient: every
    /// attachment promised by the decoded records must be present as well.
    private static func validateDeclaredAttachments(_ library: PersistedLibrary, inventory: [String: Entry]) throws {
        func component(_ name: String) throws -> String {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  !name.utf8.contains(0) else { throw Failure.unsafePath }
            return name
        }
        func requiredFile(_ components: [String], bytes: Int64? = nil) throws {
            let path = try components.map(component).joined(separator: "/")
            guard let file = inventory[path], file.kind == "file",
                  bytes == nil || (bytes! >= 0 && file.bytes == bytes!) else { throw Failure.missingDeclaredAttachment }
        }
        for work in library.existingWorks {
            for attachment in work.attachments { try requiredFile(["Attachments", work.id, attachment.storedName]) }
        }
        for certificate in library.certificates {
            for attachment in certificate.attachments { try requiredFile(["CertificateAttachments", certificate.id, attachment.storedName]) }
        }
        var folders: [String: DocumentFolder] = [:]
        for folder in library.documentFolders {
            guard folders.updateValue(folder, forKey: folder.id) == nil else { throw Failure.invalidLibrary }
        }
        for document in library.managedDocuments {
            guard let folder = folders[document.folderID] else { throw Failure.missingDeclaredAttachment }
            try requiredFile(["ManagedDocuments", folder.libraryKind.rawValue, folder.id, document.storedName], bytes: document.byteCount)
        }
        for item in library.trashItems {
            let payload = ["TrashStorage", try component(item.id), "payload"]
            switch item.kind {
            case .work:
                guard let work = item.work else { throw Failure.invalidLibrary }
                for attachment in work.attachments { try requiredFile(payload + [attachment.storedName]) }
            case .certificate:
                guard let certificate = item.certificate else { throw Failure.invalidLibrary }
                for attachment in certificate.attachments { try requiredFile(payload + [attachment.storedName]) }
            case .documentFolder:
                guard let folder = item.documentFolder else { throw Failure.invalidLibrary }
                for document in item.documents {
                    guard document.folderID == folder.id else { throw Failure.invalidLibrary }
                    try requiredFile(payload + [document.storedName], bytes: document.byteCount)
                }
            case .document:
                guard item.documents.count == 1, let document = item.documents.first else { throw Failure.invalidLibrary }
                _ = try component(document.storedName); _ = try component(document.folderID)
                try requiredFile(payload, bytes: document.byteCount)
            case .workAttachment, .certificateAttachment:
                guard let attachment = item.attachment, let parentID = item.parentID else { throw Failure.invalidLibrary }
                _ = try component(attachment.storedName); _ = try component(parentID)
                try requiredFile(payload)
            case .submission, .project, .funding:
                break // These records declare no physical payload in schema32.
            }
        }
    }
    private static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    private static func command(_ path: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.commandFailed }
    }
    private static func syncFile(_ url: URL) throws { try sync(url, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    private static func syncDirectory(_ url: URL) throws { try sync(url, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_DIRECTORY) }
    private static func sync(_ url: URL, flags: Int32) throws {
        let fd = open(url.path, flags); guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }; guard fsync(fd) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
