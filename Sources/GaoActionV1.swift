import Foundation
import CryptoKit
import Security
import Darwin

/// The sender identity, nonce and references are declarations, never authorization.
enum GaoJSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), array([GaoJSONValue]), object([String: GaoJSONValue]), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
        else if let array = try? value.decode([GaoJSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: GaoJSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        case .null: try value.encodeNil()
        }
    }
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var arrayValue: [GaoJSONValue]? { if case .array(let value) = self { return value }; return nil }
    var objectValue: [String: GaoJSONValue]? { if case .object(let value) = self { return value }; return nil }
}

enum GaoActionISO8601 {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func date(_ string: String) -> Date? {
        guard string.hasSuffix("Z"), string.utf8.count <= 40 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

struct GaoActionDeclaredIdentity: Codable, Equatable {
    var volumeUUID: String?
    var device: UInt64?
    var inode: UInt64?
    var byteCount: Int64?
    var modifiedAt: String?
    init(volumeUUID: String? = nil, device: UInt64? = nil, inode: UInt64? = nil, byteCount: Int64? = nil, modifiedAt: String? = nil) {
        self.volumeUUID = volumeUUID; self.device = device; self.inode = inode
        self.byteCount = byteCount; self.modifiedAt = modifiedAt
    }
    // Missing fields stay explicitly null in the wire format; they are never fabricated.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(volumeUUID, forKey: .volumeUUID); try c.encode(device, forKey: .device)
        try c.encode(inode, forKey: .inode); try c.encode(byteCount, forKey: .byteCount)
        try c.encode(modifiedAt, forKey: .modifiedAt)
    }
}

struct GaoActionReference: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var fileURL: String
    var displayName: String
    var declaredIdentity: GaoActionDeclaredIdentity
    var bundleID: String?
    var sha256: String?
    init(id: String = UUID().uuidString, kind: String, fileURL: String, displayName: String,
         declaredIdentity: GaoActionDeclaredIdentity, bundleID: String? = nil, sha256: String? = nil) {
        self.id = id; self.kind = kind; self.fileURL = fileURL; self.displayName = displayName
        self.declaredIdentity = declaredIdentity; self.bundleID = bundleID; self.sha256 = sha256
    }
    static func capture(at url: URL, kind: String, bundleID: String? = nil, displayName: String? = nil) throws -> Self {
        guard url.isFileURL else { throw GaoActionError.invalidReference }
        let normalized = GaoActionFileAccess.canonicalFileURL(url)
        var identity = GaoActionDeclaredIdentity()
        var checksum: String?
        if kind == "file" {
            let fingerprint = try GaoActionFileAccess.fingerprint(at: normalized)
            identity = fingerprint.identity; checksum = fingerprint.sha256
        } else {
            let fd = try GaoSecureFD.openDirectory(normalized, requireOwnedFinal: false)
            defer { close(fd) }
            let info = try GaoSecureFD.stat(fd)
            identity = GaoSecureFD.identity(info, url: normalized)
        }
        return .init(kind: kind, fileURL: normalized.absoluteString, displayName: displayName ?? normalized.lastPathComponent,
                     declaredIdentity: identity, bundleID: bundleID, sha256: checksum)
    }
}

struct GaoActionItem: Codable, Equatable, Identifiable {
    var id: String
    var relativePath: String
    var uti: String
    var byteCount: Int64
    var sha256: String
}

struct GaoActionManifest: Codable, Equatable {
    var schemaVersion: Int
    var kind: String
    var requestID: String
    var sourceBundleID: String
    var targetBundleID: String
    var action: String
    var createdAt: String
    var expiresAt: String
    var nonce: String
    var items: [GaoActionItem]
    var references: [GaoActionReference]
    var parameters: [String: GaoJSONValue]
    var inReplyTo: String?
    var status: String?
    var errorCode: String?
    var provenance: [String: GaoJSONValue]?
    init(schemaVersion: Int = 1, kind: String = "request", requestID: String = UUID().uuidString,
         sourceBundleID: String, targetBundleID: String, action: String,
         createdAt: String = GaoActionISO8601.string(Date()),
         expiresAt: String = GaoActionISO8601.string(Date().addingTimeInterval(120)),
         nonce: String = "", items: [GaoActionItem] = [], references: [GaoActionReference] = [],
         parameters: [String: GaoJSONValue] = [:], inReplyTo: String? = nil, status: String? = nil,
         errorCode: String? = nil, provenance: [String: GaoJSONValue]? = nil) {
        self.schemaVersion = schemaVersion; self.kind = kind; self.requestID = requestID
        self.sourceBundleID = sourceBundleID; self.targetBundleID = targetBundleID; self.action = action
        self.createdAt = createdAt; self.expiresAt = expiresAt; self.nonce = nonce; self.items = items
        self.references = references; self.parameters = parameters; self.inReplyTo = inReplyTo
        self.status = status; self.errorCode = errorCode; self.provenance = provenance
    }
}

struct GaoActionLimits {
    var maximumManifestBytes = 1_048_576
    var maximumItems = 256
    var maximumPayloadBytes: Int64 = 2 * 1024 * 1024 * 1024
    var ttl: TimeInterval = 120
    static let `default` = GaoActionLimits()
}

enum GaoActionError: Error, LocalizedError, Equatable {
    case unsupportedVersion, invalidManifest, wrongTarget, expired, invalidNonce, unknownAction, invalidParameters
    case invalidReference, unsafePath, unsafeFile, permissionDenied, sourceChanged, checksumMismatch, byteCountMismatch
    case manifestTooLarge, tooManyItems, payloadTooLarge, ioFailure, packageAlreadyExists
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "不支持此交接包版本。"
        case .invalidManifest: return "交接清单字段或结果关联不合法。"
        case .wrongTarget: return "交接包目标应用不匹配。"
        case .expired: return "交接包已过期或时间范围不合法，请发送方重新发送。"
        case .invalidNonce: return "交接包随机数格式不合法。"
        case .unknownAction: return "不支持此交接动作。"
        case .invalidParameters: return "交接动作包含不允许的参数或输入。"
        case .invalidReference: return "外部引用格式不合法；引用本身不授予访问权限。"
        case .unsafePath: return "交接文件路径不安全。"
        case .unsafeFile: return "交接内容必须是本人可读取的普通文件副本，不能是链接或目录。"
        case .permissionDenied: return "当前应用无法读取交接内容，请重新选择有权限的文件。"
        case .sourceChanged: return "复制期间文件发生变化，已停止处理，请重新发送。"
        case .checksumMismatch: return "交接内容摘要不一致，已停止处理。"
        case .byteCountMismatch: return "交接内容大小与清单不一致。"
        case .manifestTooLarge: return "交接清单超过 1 MiB，请分批发送。"
        case .tooManyItems: return "交接文件超过 256 项，请分批发送。"
        case .payloadTooLarge: return "交接文件总量超过 2 GiB，请分批或另选文件。"
        case .ioFailure: return "交接文件读写失败，原件未修改。"
        case .packageAlreadyExists: return "交接包标识已存在，请使用新的请求标识。"
        }
    }
}

struct GaoStagedActionItem {
    let item: GaoActionItem
    let url: URL
    var originalFilename: String { (item.relativePath as NSString).lastPathComponent }
}
struct GaoValidatedActionPackage {
    let manifest: GaoActionManifest
    let stagingDirectory: URL
    let stagedItems: [GaoStagedActionItem]
}
struct GaoActionFileFingerprint {
    let byteCount: Int64
    let sha256: String
    let identity: GaoActionDeclaredIdentity
}

enum GaoActionFileAccess {
    /// Lexical file-URL normalization must not use Foundation's private-prefix rewriting
    /// (e.g. /private/tmp → /tmp), which can introduce a symlink into an otherwise safe path.
    static func canonicalFileURL(_ url: URL) -> URL {
        var components: [String] = []
        for piece in url.path.split(separator: "/") {
            if piece == "." { continue }
            if piece == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(String(piece))
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: url.hasDirectoryPath)
    }
    static func ensurePrivateDirectory(at url: URL) throws {
        let fd = try GaoSecureFD.openDirectory(url, requireOwnedFinal: true, create: true)
        defer { close(fd) }
        guard fchmod(fd, 0o700) == 0 else { throw GaoActionError.ioFailure }
    }
    static func readPrivateData(at url: URL, maximumBytes: Int = 1_048_576) throws -> Data {
        guard maximumBytes >= 0 else { throw GaoActionError.invalidManifest }
        let fd = try GaoSecureFD.openRegularFile(url)
        defer { close(fd) }
        let before = try GaoSecureFD.stat(fd)
        guard before.st_size >= 0, before.st_size <= maximumBytes else { throw GaoActionError.manifestTooLarge }
        let data = try GaoSecureFD.readBounded(fd, maximum: maximumBytes)
        guard GaoSecureFD.unchanged(before, try GaoSecureFD.stat(fd)) else { throw GaoActionError.sourceChanged }
        return data
    }
    static func writePrivateData(_ data: Data, to url: URL) throws {
        let parent = try GaoSecureFD.openDirectory(url.deletingLastPathComponent(), requireOwnedFinal: true, create: true)
        defer { close(parent) }
        guard fchmod(parent, 0o700) == 0 else { throw GaoActionError.ioFailure }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw GaoActionError.unsafePath }
        var existing = Darwin.stat()
        if fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1 else { throw GaoActionError.unsafeFile }
            guard existing.st_uid == geteuid() else { throw GaoActionError.permissionDenied }
        } else if errno != ENOENT { throw GaoActionError.ioFailure }
        let temporary = ".write-" + UUID().uuidString
        let fd = try GaoSecureFD.createFile(at: parent, name: temporary)
        var completed = false
        defer { close(fd); if !completed { unlinkat(parent, temporary, 0) } }
        try GaoSecureFD.writeAll(data, to: fd)
        guard fsync(fd) == 0, renameat(parent, temporary, parent, name) == 0, fsync(parent) == 0 else { throw GaoActionError.ioFailure }
        completed = true
    }
    /// Copies a selected file into an app-owned private directory without reopening its source path.
    /// The destination must not already exist. On failure only this newly-created copy is removed.
    static func copyRegularFile(at sourceURL: URL, to destinationURL: URL,
                                maximumBytes: Int64 = 2 * 1024 * 1024 * 1024) throws -> GaoActionFileFingerprint {
        let source = try GaoSecureFD.openRegularFile(sourceURL)
        defer { close(source) }
        let before = try GaoSecureFD.stat(source)
        let parent = try GaoSecureFD.openDirectory(destinationURL.deletingLastPathComponent(), requireOwnedFinal: true, create: true)
        defer { close(parent) }
        guard fchmod(parent, 0o700) == 0 else { throw GaoActionError.ioFailure }
        let name = destinationURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw GaoActionError.unsafePath }
        let destination = try GaoSecureFD.createFile(at: parent, name: name)
        var succeeded = false
        defer { close(destination); if !succeeded { unlinkat(parent, name, 0) } }
        let result = try GaoSecureFD.stream(source, into: destination, expectedCount: Int64(before.st_size), maximum: maximumBytes)
        guard GaoSecureFD.unchanged(before, try GaoSecureFD.stat(source)) else { throw GaoActionError.sourceChanged }
        guard fsync(destination) == 0 else { throw GaoActionError.ioFailure }
        succeeded = true
        return .init(byteCount: result.count, sha256: result.sha256, identity: GaoSecureFD.identity(before, url: sourceURL))
    }
    /// The descriptor remains fixed throughout hashing; changing data is rejected.
    static func fingerprint(at url: URL, limits: GaoActionLimits = .default) throws -> GaoActionFileFingerprint {
        let fd = try GaoSecureFD.openRegularFile(url)
        defer { close(fd) }
        let before = try GaoSecureFD.stat(fd)
        let copied = try GaoSecureFD.stream(fd, into: nil, expectedCount: Int64(before.st_size), maximum: limits.maximumPayloadBytes)
        guard GaoSecureFD.unchanged(before, try GaoSecureFD.stat(fd)) else { throw GaoActionError.sourceChanged }
        return .init(byteCount: copied.count, sha256: copied.sha256, identity: GaoSecureFD.identity(before, url: url))
    }
}

struct GaoActionPackageValidator {
    let expectedTargetBundleID: String
    var now: Date
    var limits: GaoActionLimits
    init(expectedTargetBundleID: String, now: Date = Date(), limits: GaoActionLimits = .default) {
        self.expectedTargetBundleID = expectedTargetBundleID; self.now = now; self.limits = limits
    }
    func validateManifestData(_ data: Data) throws -> GaoActionManifest {
        guard data.count <= limits.maximumManifestBytes else { throw GaoActionError.manifestTooLarge }
        try GaoUniqueJSONKeys.validate(data)
        let allowed: Set<String> = ["schemaVersion", "kind", "requestID", "sourceBundleID", "targetBundleID", "action", "createdAt", "expiresAt", "nonce", "items", "references", "parameters", "inReplyTo", "status", "errorCode", "provenance"]
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: allowed),
              let manifest = try? JSONDecoder().decode(GaoActionManifest.self, from: data) else { throw GaoActionError.invalidManifest }
        try validateManifest(manifest)
        return manifest
    }
    func validateManifest(_ manifest: GaoActionManifest) throws {
        guard manifest.schemaVersion == 1 else { throw GaoActionError.unsupportedVersion }
        guard manifest.targetBundleID == expectedTargetBundleID else { throw GaoActionError.wrongTarget }
        guard GaoActionContract.isUUID(manifest.requestID), GaoActionContract.isBundleID(manifest.sourceBundleID),
              GaoActionContract.isBundleID(manifest.targetBundleID), ["request", "result"].contains(manifest.kind) else { throw GaoActionError.invalidManifest }
        guard let nonce = Data(base64Encoded: manifest.nonce), nonce.count == 32,
              nonce.base64EncodedString() == manifest.nonce else { throw GaoActionError.invalidNonce }
        guard let created = GaoActionISO8601.date(manifest.createdAt), let expires = GaoActionISO8601.date(manifest.expiresAt),
              created <= now, expires > now, expires > created,
              expires.timeIntervalSince(created) <= limits.ttl + 0.001 else { throw GaoActionError.expired }
        if manifest.kind == "result" {
            guard let reply = manifest.inReplyTo, GaoActionContract.isUUID(reply),
                  let status = manifest.status, ["pending", "completed", "partial", "cancelled", "failed", "unsupported"].contains(status),
                  manifest.provenance != nil else { throw GaoActionError.invalidManifest }
        } else {
            guard manifest.inReplyTo == nil, manifest.status == nil, manifest.errorCode == nil, manifest.provenance == nil else { throw GaoActionError.invalidManifest }
        }
        guard manifest.items.count <= limits.maximumItems else { throw GaoActionError.tooManyItems }
        var total: Int64 = 0
        var ids = Set<String>(), paths = Set<String>()
        for item in manifest.items {
            guard !item.id.isEmpty, item.id.utf8.count <= 256, ids.insert(item.id).inserted,
                  paths.insert(item.relativePath).inserted, !item.uti.isEmpty, item.uti.utf8.count <= 256,
                  item.byteCount >= 0, GaoActionContract.isSHA256(item.sha256) else { throw GaoActionError.invalidManifest }
            _ = try GaoSecureFD.payloadComponents(item.relativePath)
            let addition = total.addingReportingOverflow(item.byteCount)
            guard !addition.overflow, addition.partialValue <= limits.maximumPayloadBytes else { throw GaoActionError.payloadTooLarge }
            total = addition.partialValue
        }
        var referenceIDs = Set<String>()
        for reference in manifest.references {
            guard !reference.id.isEmpty, reference.id.utf8.count <= 256, referenceIDs.insert(reference.id).inserted else { throw GaoActionError.invalidReference }
            try GaoActionContract.validateReference(reference)
        }
        try GaoActionContract.validateAction(manifest)
        if let provenance = manifest.provenance { try GaoActionContract.rejectExecutableKeys(.object(provenance)) }
    }
    /// Validates the untrusted package, then copies into a private, bounded receiver staging.
    /// Only stagedItems may be passed to the business importer. The sender's package is untouched.
    func stagePackage(at packageURL: URL, stagingRoot: URL) throws -> GaoValidatedActionPackage {
        guard packageURL.pathExtension.lowercased() == "gaoaction" else { throw GaoActionError.invalidManifest }
        let packageFD = try GaoSecureFD.openDirectory(packageURL, requireOwnedFinal: true)
        defer { close(packageFD) }
        let manifestFD = try GaoSecureFD.openRegularFile(at: packageFD, name: "manifest.json")
        defer { close(manifestFD) }
        let beforeManifest = try GaoSecureFD.stat(manifestFD)
        guard beforeManifest.st_size >= 0, beforeManifest.st_size <= limits.maximumManifestBytes else { throw GaoActionError.manifestTooLarge }
        let data = try GaoSecureFD.readBounded(manifestFD, maximum: limits.maximumManifestBytes)
        guard GaoSecureFD.unchanged(beforeManifest, try GaoSecureFD.stat(manifestFD)) else { throw GaoActionError.sourceChanged }
        let manifest = try validateManifestData(data)
        let payloadFD = try GaoSecureFD.openChildDirectory(at: packageFD, name: "payload", owned: true)
        defer { close(payloadFD) }
        let staging = try GaoSecureFD.makePrivateChild(in: stagingRoot, name: UUID().uuidString)
        var succeeded = false
        defer { close(staging.fd); if !succeeded { try? FileManager.default.removeItem(at: staging.url) } }
        var copied: [GaoStagedActionItem] = []
        var total: Int64 = 0
        for item in manifest.items {
            let components = try GaoSecureFD.payloadComponents(item.relativePath)
            let source = try GaoSecureFD.openRelativeRegularFile(at: payloadFD, components: Array(components.dropFirst()))
            defer { close(source) }
            let before = try GaoSecureFD.stat(source)
            guard Int64(before.st_size) == item.byteCount else { throw GaoActionError.byteCountMismatch }
            let ext = (item.relativePath as NSString).pathExtension
            let suffix = ext.range(of: "^[A-Za-z0-9]{1,16}$", options: .regularExpression) == nil ? "" : "." + ext
            let filename = UUID().uuidString + suffix
            let destination = try GaoSecureFD.createFile(at: staging.fd, name: filename)
            do {
                let bytes = try GaoSecureFD.stream(source, into: destination, expectedCount: item.byteCount, maximum: limits.maximumPayloadBytes - total)
                guard GaoSecureFD.unchanged(before, try GaoSecureFD.stat(source)) else { throw GaoActionError.sourceChanged }
                guard bytes.count == item.byteCount else { throw GaoActionError.byteCountMismatch }
                guard bytes.sha256 == item.sha256.lowercased() else { throw GaoActionError.checksumMismatch }
                total += bytes.count
                guard fsync(destination) == 0 else { throw GaoActionError.ioFailure }
                close(destination)
            } catch { close(destination); throw error }
            copied.append(.init(item: item, url: staging.url.appendingPathComponent(filename)))
        }
        guard GaoSecureFD.unchanged(beforeManifest, try GaoSecureFD.stat(manifestFD)) else { throw GaoActionError.sourceChanged }
        succeeded = true
        return .init(manifest: manifest, stagingDirectory: staging.url, stagedItems: copied)
    }
}

struct GaoActionPackageWriter {
    var limits: GaoActionLimits = .default
    /// The manifest template supplies IDs/UTIs/relative paths, not trusted size or digest values.
    /// Production packages always receive a fresh nonce and a fresh 120-second lifetime.
    func write(manifest template: GaoActionManifest, files: [String: URL], outgoingRoot: URL) throws -> URL {
        var manifest = template
        guard GaoActionContract.isUUID(manifest.requestID), manifest.items.count <= limits.maximumItems,
              Set(files.keys) == Set(manifest.items.map(\.id)) else { throw GaoActionError.invalidManifest }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw GaoActionError.ioFailure }
        manifest.nonce = Data(random).base64EncodedString()
        let now = Date()
        manifest.createdAt = GaoActionISO8601.string(now)
        manifest.expiresAt = GaoActionISO8601.string(now.addingTimeInterval(limits.ttl))
        let temporaryName = ".building-" + UUID().uuidString
        let building = try GaoSecureFD.makePrivateChild(in: outgoingRoot, name: temporaryName)
        var succeeded = false
        defer { close(building.fd); if !succeeded { try? FileManager.default.removeItem(at: building.url) } }
        guard mkdirat(building.fd, "payload", 0o700) == 0 else { throw GaoActionError.ioFailure }
        let payload = try GaoSecureFD.openChildDirectory(at: building.fd, name: "payload", owned: true)
        defer { close(payload) }
        var total: Int64 = 0
        for index in manifest.items.indices {
            let item = manifest.items[index]
            let components = try GaoSecureFD.payloadComponents(item.relativePath)
            guard let sourceURL = files[item.id] else { throw GaoActionError.invalidManifest }
            let source = try GaoSecureFD.openRegularFile(sourceURL)
            defer { close(source) }
            let before = try GaoSecureFD.stat(source)
            guard before.st_size >= 0, Int64(before.st_size) <= limits.maximumPayloadBytes - total else { throw GaoActionError.payloadTooLarge }
            let destination = try GaoSecureFD.createRelativeFile(at: payload, components: Array(components.dropFirst()))
            do {
                let bytes = try GaoSecureFD.stream(source, into: destination, expectedCount: Int64(before.st_size), maximum: limits.maximumPayloadBytes - total)
                guard GaoSecureFD.unchanged(before, try GaoSecureFD.stat(source)) else { throw GaoActionError.sourceChanged }
                guard fsync(destination) == 0 else { throw GaoActionError.ioFailure }
                close(destination)
                manifest.items[index].byteCount = bytes.count
                manifest.items[index].sha256 = bytes.sha256
                total += bytes.count
            } catch { close(destination); throw error }
        }
        let validator = GaoActionPackageValidator(expectedTargetBundleID: manifest.targetBundleID, now: Date(), limits: limits)
        try validator.validateManifest(manifest)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        guard data.count <= limits.maximumManifestBytes else { throw GaoActionError.manifestTooLarge }
        let manifestName = ".manifest-" + UUID().uuidString
        let output = try GaoSecureFD.createFile(at: building.fd, name: manifestName)
        do { try GaoSecureFD.writeAll(data, to: output); guard fsync(output) == 0 else { throw GaoActionError.ioFailure }; close(output) }
        catch { close(output); throw error }
        guard renameat(building.fd, manifestName, building.fd, "manifest.json") == 0, fsync(building.fd) == 0 else { throw GaoActionError.ioFailure }
        let root = try GaoSecureFD.openDirectory(outgoingRoot, requireOwnedFinal: true)
        defer { close(root) }
        let finalName = manifest.requestID + ".gaoaction"
        guard renameatx_np(root, temporaryName, root, finalName, UInt32(RENAME_EXCL)) == 0 else {
            throw errno == EEXIST ? GaoActionError.packageAlreadyExists : GaoActionError.ioFailure
        }
        guard fsync(root) == 0 else { throw GaoActionError.ioFailure }
        succeeded = true
        return outgoingRoot.appendingPathComponent(finalName, isDirectory: true)
    }
}

private enum GaoActionContract {
    static func isUUID(_ value: String) -> Bool {
        value.range(of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$", options: .regularExpression) != nil && UUID(uuidString: value) != nil
    }
    static func isBundleID(_ value: String) -> Bool {
        value.utf8.count <= 255 && value.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil
    }
    static func isSHA256(_ value: String) -> Bool { value.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil }
    static func validateReference(_ reference: GaoActionReference) throws {
        guard ["file", "directory", "application"].contains(reference.kind),
              let url = URL(string: reference.fileURL), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, url.user == nil, url.password == nil,
              url.path.hasPrefix("/"), !url.path.utf8.contains(0),
              GaoActionFileAccess.canonicalFileURL(url).absoluteString == reference.fileURL,
              !reference.displayName.isEmpty, reference.displayName.utf8.count <= 1024,
              reference.declaredIdentity.byteCount.map({ $0 >= 0 }) ?? true,
              reference.declaredIdentity.modifiedAt.map({ GaoActionISO8601.date($0) != nil }) ?? true,
              reference.sha256.map(isSHA256) ?? true else { throw GaoActionError.invalidReference }
        if reference.kind == "application" {
            guard let bundleID = reference.bundleID, isBundleID(bundleID) else { throw GaoActionError.invalidReference }
        } else if reference.bundleID != nil { throw GaoActionError.invalidReference }
    }
    static func rejectExecutableKeys(_ value: GaoJSONValue) throws {
        switch value {
        case .object(let object):
            let forbidden: Set<String> = ["shell", "script", "command", "argv", "callbackurl", "browserarguments", "elevate", "sudo", "password", "cookie"]
            for (key, child) in object {
                guard !forbidden.contains(key.lowercased()) else { throw GaoActionError.invalidParameters }
                try rejectExecutableKeys(child)
            }
        case .array(let array): for child in array { try rejectExecutableKeys(child) }
        default: break
        }
    }
    static func validateAction(_ m: GaoActionManifest) throws {
        let schema: [String: Set<String>] = [
            "capture.region": ["delaySeconds"], "capture.window": ["delaySeconds"], "capture.display": ["delaySeconds"],
            "ocr.files": ["languages", "outputs"], "images.annotate": [], "images.pin": [],
            "text.translate": ["sourceLanguage", "targetLanguage"], "storage.inspect": ["mode"], "cleanup.review": [],
            "apps.uninstall.review": [], "files.search": ["query"], "files.choose": ["allowedUTIs", "multiple"],
            "files.reveal": [], "associations.manage": ["uti"], "documents.open": [], "documents.newText": ["suggestedTitle"],
            "research.importDocuments": ["targetRecordID"], "portal.openSite": ["siteID", "browserID"],
            "portal.openWorkspace": ["workspaceID"], "portal.focusSearch": ["query"], "portal.proposeSite": ["url", "title"],
            "portal.prepareDownload": ["urls"], "windows.overview": [], "desktop.openSettings": [], "downloads.prepare": ["urls", "mediaType"]
        ]
        guard let keys = schema[m.action] else { throw GaoActionError.unknownAction }
        if m.kind == "request" {
            let owners: [String: String] = [
                "capture": "com.gaoseries.GaoJieTu", "ocr": "com.gaoseries.GaoJieTu", "images": "com.gaoseries.GaoJieTu", "text": "com.gaoseries.GaoJieTu",
                "storage": "com.gaoseries.GaoJiLing", "cleanup": "com.gaoseries.GaoJiLing", "apps": "com.gaoseries.GaoJiLing",
                "files": "com.gaoseries.GaoZhengLi", "associations": "com.gaoseries.GaoZhengLi", "documents": "com.gaoseries.GaoWenJian",
                "research": "com.academic-achievement.manager", "portal": "cn.mendao.launcher",
                "windows": "com.gaoseries.GaoZhuoMian", "desktop": "com.gaoseries.GaoZhuoMian", "downloads": "com.gaoseries.GaoXiaZai"
            ]
            guard let prefix = m.action.split(separator: ".").first, owners[String(prefix)] == m.targetBundleID else { throw GaoActionError.wrongTarget }
        }
        guard Set(m.parameters.keys).isSubset(of: keys) else { throw GaoActionError.invalidParameters }
        try rejectExecutableKeys(.object(m.parameters))
        let p = m.parameters
        func string(_ key: String, max: Int = 4096, required: Bool = false) throws -> String? {
            guard let value = p[key] else { if required { throw GaoActionError.invalidParameters }; return nil }
            guard case .string(let result) = value, !result.isEmpty, result.count <= max, !result.utf8.contains(0) else { throw GaoActionError.invalidParameters }
            return result
        }
        func strings(_ key: String, max: Int = 256) throws -> [String]? {
            guard let value = p[key] else { return nil }
            guard case .array(let array) = value, !array.isEmpty, array.count <= max else { throw GaoActionError.invalidParameters }
            return try array.map { value in
                guard case .string(let string) = value, !string.isEmpty, string.count <= 256, !string.utf8.contains(0) else { throw GaoActionError.invalidParameters }
                return string
            }
        }
        func language(_ value: String) -> Bool { value.range(of: "^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$", options: .regularExpression) != nil }
        func webURL(_ value: String) -> Bool {
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
            return true
        }
        let request = m.kind == "request"
        switch m.action {
        case "capture.region", "capture.window", "capture.display":
            if let value = p["delaySeconds"] { guard case .number(let seconds) = value, seconds >= 0, seconds <= 60 else { throw GaoActionError.invalidParameters } }
        case "ocr.files":
            if let languages = try strings("languages") { guard languages.allSatisfy(language) else { throw GaoActionError.invalidParameters } }
            if let outputs = try strings("outputs", max: 4) { guard Set(outputs).isSubset(of: ["text", "markdown", "json", "searchablePDF"]), Set(outputs).count == outputs.count else { throw GaoActionError.invalidParameters } }
        case "text.translate":
            if let source = try string("sourceLanguage", max: 64) { guard source == "auto" || language(source) else { throw GaoActionError.invalidParameters } }
            if let target = try string("targetLanguage", max: 64, required: request) { guard language(target) else { throw GaoActionError.invalidParameters } }
        case "storage.inspect":
            if let mode = try string("mode") { guard ["metadata", "duplicates"].contains(mode) else { throw GaoActionError.invalidParameters } }
        case "files.search": _ = try string("query", required: request)
        case "files.choose":
            _ = try strings("allowedUTIs")
            if let multiple = p["multiple"], multiple.boolValue == nil { throw GaoActionError.invalidParameters }
        case "associations.manage": _ = try string("uti", max: 256)
        case "documents.newText": _ = try string("suggestedTitle", max: 256)
        case "research.importDocuments": _ = try string("targetRecordID", max: 256)
        case "portal.openSite": _ = try string("siteID", max: 256, required: request); _ = try string("browserID", max: 256)
        case "portal.openWorkspace": _ = try string("workspaceID", max: 256, required: request)
        case "portal.focusSearch": _ = try string("query")
        case "portal.proposeSite":
            if let url = try string("url", required: request) { guard webURL(url) else { throw GaoActionError.invalidParameters } }
            _ = try string("title", max: 256)
        case "portal.prepareDownload", "downloads.prepare":
            let urls = try strings("urls", max: 32)
            guard !request || urls != nil else { throw GaoActionError.invalidParameters }
            if let urls = urls { guard urls.allSatisfy(webURL) else { throw GaoActionError.invalidParameters } }
            if let type = try string("mediaType") { guard ["file", "video", "audio", "image", "subtitle"].contains(type) else { throw GaoActionError.invalidParameters } }
        default: break
        }
        guard request else { return }
        let noPayload: Set<String> = ["capture.region", "capture.window", "capture.display", "cleanup.review", "associations.manage", "portal.openSite", "portal.openWorkspace", "portal.focusSearch", "portal.proposeSite", "portal.prepareDownload", "windows.overview", "desktop.openSettings", "downloads.prepare"]
        if noPayload.contains(m.action) { guard m.items.isEmpty, m.references.isEmpty else { throw GaoActionError.invalidParameters } }
        switch m.action {
        case "ocr.files": guard !m.items.isEmpty, m.references.isEmpty, m.items.allSatisfy({ isImage($0.uti) || ["com.adobe.pdf", "application/pdf"].contains($0.uti) }) else { throw GaoActionError.invalidParameters }
        case "images.annotate", "images.pin": guard m.items.count == 1, isImage(m.items[0].uti), m.references.isEmpty else { throw GaoActionError.invalidParameters }
        case "text.translate": guard m.items.count == 1, ["public.plain-text", "text/plain", "public.utf8-plain-text"].contains(m.items[0].uti), m.references.isEmpty else { throw GaoActionError.invalidParameters }
        case "storage.inspect": guard m.items.isEmpty, m.references.count == 1, m.references[0].kind == "directory" else { throw GaoActionError.invalidParameters }
        case "apps.uninstall.review": guard m.items.isEmpty, m.references.count == 1, m.references[0].kind == "application" else { throw GaoActionError.invalidParameters }
        case "files.search", "files.choose": guard m.items.isEmpty, m.references.count <= 1, m.references.allSatisfy({ $0.kind == "directory" }) else { throw GaoActionError.invalidParameters }
        case "files.reveal": guard m.items.isEmpty, m.references.count == 1 else { throw GaoActionError.invalidParameters }
        case "documents.open": guard (!m.items.isEmpty && m.references.isEmpty) || (m.items.isEmpty && !m.references.isEmpty && m.references.allSatisfy({ $0.kind == "file" })) else { throw GaoActionError.invalidParameters }
        case "documents.newText": guard m.items.count == 1, ["public.plain-text", "public.utf8-plain-text", "text/plain", "text/markdown", "net.daringfireball.markdown"].contains(m.items[0].uti), m.references.isEmpty else { throw GaoActionError.invalidParameters }
        case "research.importDocuments": guard !m.items.isEmpty, m.references.isEmpty else { throw GaoActionError.invalidParameters }
        default: break
        }
        let invalidUTIs: Set<String> = ["public.folder", "public.directory", "com.apple.package", "com.apple.application-bundle", "com.apple.application"]
        guard !m.items.contains(where: { invalidUTIs.contains($0.uti) }) else { throw GaoActionError.invalidParameters }
    }
    private static func isImage(_ uti: String) -> Bool {
        ["public.image", "public.png", "public.jpeg", "public.heic", "public.heif", "public.tiff", "com.compuserve.gif", "com.microsoft.bmp", "org.webmproject.webp", "image/png", "image/jpeg", "image/tiff", "image/heic"].contains(uti)
    }
}

private enum GaoSecureFD {
    static let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    static func stat(_ fd: Int32) throws -> Darwin.stat {
        var value = Darwin.stat()
        guard fstat(fd, &value) == 0 else { throw GaoActionError.ioFailure }
        return value
    }
    static func checkDirectory(_ fd: Int32, owned: Bool) throws {
        let info = try stat(fd)
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw GaoActionError.unsafePath }
        if owned { guard info.st_uid == geteuid() else { throw GaoActionError.permissionDenied } }
    }
    static func checkFile(_ fd: Int32) throws {
        let info = try stat(fd)
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw GaoActionError.unsafeFile }
        guard info.st_uid == geteuid(), info.st_mode & S_IRUSR != 0 else { throw GaoActionError.permissionDenied }
    }
    static func openDirectory(_ url: URL, requireOwnedFinal: Bool, create: Bool = false) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw GaoActionError.unsafePath }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains(".."), !components.contains(".") else { throw GaoActionError.unsafePath }
        let fm = FileManager.default
        if create, !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let fd = Darwin.open(url.path, flags | O_DIRECTORY)
        guard fd >= 0 else { throw errno == ELOOP ? GaoActionError.unsafePath : GaoActionError.permissionDenied }
        do {
            try checkDirectory(fd, owned: requireOwnedFinal)
            return fd
        } catch { close(fd); throw error }
    }
    static func openChildDirectory(at parent: Int32, name: String, owned: Bool) throws -> Int32 {
        let fd = openat(parent, name, flags | O_DIRECTORY)
        guard fd >= 0 else { throw GaoActionError.unsafePath }
        do { try checkDirectory(fd, owned: owned); return fd } catch { close(fd); throw error }
    }
    static func openRegularFile(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw GaoActionError.unsafePath }
        let parent = try openDirectory(url.deletingLastPathComponent(), requireOwnedFinal: false)
        defer { close(parent) }
        return try openRegularFile(at: parent, name: url.lastPathComponent)
    }
    static func openRegularFile(at parent: Int32, name: String) throws -> Int32 {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw GaoActionError.unsafePath }
        // O_NONBLOCK prevents a FIFO masquerading as an attachment from hanging open().
        let fd = openat(parent, name, flags | O_NONBLOCK)
        guard fd >= 0 else { throw errno == ELOOP ? GaoActionError.unsafePath : GaoActionError.permissionDenied }
        do { try checkFile(fd); return fd } catch { close(fd); throw error }
    }
    static func payloadComponents(_ path: String) throws -> [String] {
        guard path.utf8.count <= 4096,
              path.range(of: "^payload/(?:[^/\\\\\\x00]+/)*[^/\\\\\\x00]+$", options: .regularExpression) != nil else { throw GaoActionError.unsafePath }
        let components = path.components(separatedBy: "/")
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { throw GaoActionError.unsafePath }
        return components
    }
    static func openRelativeRegularFile(at root: Int32, components: [String]) throws -> Int32 {
        guard let last = components.last else { throw GaoActionError.unsafePath }
        var current = dup(root)
        guard current >= 0 else { throw GaoActionError.ioFailure }
        defer { close(current) }
        for name in components.dropLast() {
            let next = try openChildDirectory(at: current, name: name, owned: true)
            close(current); current = next
        }
        return try openRegularFile(at: current, name: last)
    }
    static func makePrivateChild(in root: URL, name: String) throws -> (fd: Int32, url: URL) {
        let parent = try openDirectory(root, requireOwnedFinal: true, create: true)
        defer { close(parent) }
        guard fchmod(parent, 0o700) == 0, mkdirat(parent, name, 0o700) == 0 else { throw GaoActionError.ioFailure }
        let child = try openChildDirectory(at: parent, name: name, owned: true)
        return (child, root.appendingPathComponent(name, isDirectory: true))
    }
    static func createFile(at parent: Int32, name: String) throws -> Int32 {
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GaoActionError.ioFailure }
        return fd
    }
    static func createRelativeFile(at root: Int32, components: [String]) throws -> Int32 {
        guard let last = components.last else { throw GaoActionError.unsafePath }
        var current = dup(root)
        guard current >= 0 else { throw GaoActionError.ioFailure }
        defer { close(current) }
        for name in components.dropLast() {
            if mkdirat(current, name, 0o700) != 0, errno != EEXIST { throw GaoActionError.ioFailure }
            let next = try openChildDirectory(at: current, name: name, owned: true)
            close(current); current = next
        }
        return try createFile(at: current, name: last)
    }
    static func unchanged(_ a: Darwin.stat, _ b: Darwin.stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink &&
        a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    static func identity(_ info: Darwin.stat, url: URL) -> GaoActionDeclaredIdentity {
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        let volume = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return .init(volumeUUID: volume, device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
                     byteCount: Int64(info.st_size), modifiedAt: GaoActionISO8601.string(modified))
    }
    static func readBounded(_ fd: Int32, maximum: Int) throws -> Data {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw GaoActionError.ioFailure }
            guard data.count + count <= maximum else { throw GaoActionError.manifestTooLarge }
            data.append(buffer, count: count)
        }
        return data
    }
    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw GaoActionError.ioFailure }
                guard count > 0 else { throw GaoActionError.ioFailure }
                offset += count
            }
        }
    }
    static func stream(_ source: Int32, into destination: Int32?, expectedCount: Int64, maximum: Int64) throws -> (count: Int64, sha256: String) {
        guard expectedCount >= 0, expectedCount <= maximum else { throw GaoActionError.payloadTooLarge }
        var hash = SHA256(), count: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let received = Darwin.read(source, &buffer, buffer.count)
            if received == 0 { break }
            if received < 0 { if errno == EINTR { continue }; throw GaoActionError.ioFailure }
            guard Int64(received) <= maximum - count else { throw GaoActionError.payloadTooLarge }
            count += Int64(received)
            guard count <= expectedCount else { throw GaoActionError.sourceChanged }
            let bytes = Data(buffer[0..<received])
            hash.update(data: bytes)
            if let destination = destination { try writeAll(bytes, to: destination) }
        }
        guard count == expectedCount else { throw GaoActionError.byteCountMismatch }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

/// Bounded syntax walk detecting duplicate logical keys (including \u-escaped keys).
/// JSONSerialization alone silently keeps one value, which permits different interpretations.
private struct GaoUniqueJSONKeys {
    var bytes: [UInt8]
    var offset = 0
    static func validate(_ data: Data) throws {
        var parser = GaoUniqueJSONKeys(bytes: Array(data))
        try parser.value(depth: 0)
        parser.whitespace()
        guard parser.offset == parser.bytes.count else { throw GaoActionError.invalidManifest }
    }
    mutating func whitespace() {
        while offset < bytes.count, [UInt8(0x20), 0x09, 0x0A, 0x0D].contains(bytes[offset]) { offset += 1 }
    }
    mutating func consume(_ byte: UInt8) throws {
        whitespace()
        guard offset < bytes.count, bytes[offset] == byte else { throw GaoActionError.invalidManifest }
        offset += 1
    }
    mutating func string() throws -> Range<Int> {
        whitespace()
        let start = offset
        try consume(0x22)
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if byte == 0x22 { return start..<offset }
            guard byte >= 0x20 else { throw GaoActionError.invalidManifest }
            if byte == 0x5C { guard offset < bytes.count else { throw GaoActionError.invalidManifest }; offset += 1 }
        }
        throw GaoActionError.invalidManifest
    }
    mutating func value(depth: Int) throws {
        whitespace()
        guard depth <= 64, offset < bytes.count else { throw GaoActionError.invalidManifest }
        switch bytes[offset] {
        case 0x7B:
            offset += 1; whitespace()
            var keys = Set<String>()
            if offset < bytes.count, bytes[offset] == 0x7D { offset += 1; return }
            while true {
                let range = try string()
                guard let key = try? JSONDecoder().decode(String.self, from: Data(bytes[range])), keys.insert(key).inserted else { throw GaoActionError.invalidManifest }
                try consume(0x3A); try value(depth: depth + 1); whitespace()
                guard offset < bytes.count else { throw GaoActionError.invalidManifest }
                if bytes[offset] == 0x7D { offset += 1; return }
                try consume(0x2C)
            }
        case 0x5B:
            offset += 1; whitespace()
            if offset < bytes.count, bytes[offset] == 0x5D { offset += 1; return }
            while true {
                try value(depth: depth + 1); whitespace()
                guard offset < bytes.count else { throw GaoActionError.invalidManifest }
                if bytes[offset] == 0x5D { offset += 1; return }
                try consume(0x2C)
            }
        case 0x22: _ = try string()
        case 0x74: try literal("true")
        case 0x66: try literal("false")
        case 0x6E: try literal("null")
        default:
            let start = offset
            while offset < bytes.count, [UInt8(0x2D), 0x2B, 0x2E, 0x45, 0x65].contains(bytes[offset]) || (offset < bytes.count && bytes[offset] >= 0x30 && bytes[offset] <= 0x39) { offset += 1 }
            guard offset > start else { throw GaoActionError.invalidManifest }
        }
    }
    mutating func literal(_ text: String) throws {
        let value = Array(text.utf8)
        guard offset + value.count <= bytes.count, Array(bytes[offset..<(offset + value.count)]) == value else { throw GaoActionError.invalidManifest }
        offset += value.count
    }
}
