import CryptoKit
import Darwin
import Foundation

struct ResearchOCRReturnTicket: Codable, Equatable {
    let schemaVersion: Int
    let requestID: String
    let action: String
    let sourceBundleID: String
    let targetBundleID: String
    let requestManifestSHA256: String
    let expiresAt: String
}

struct ResearchOCRReturnReceipt: Codable {
    let resultID: String
    let manifestSHA256: String
    let receivedAt: Date
    let stagingID: String
    let stagedNames: [String: String]
}

/// GaoAction's fixed, user-local return slot. It never accepts a callback URL or searches other apps' files.
struct ResearchOCRReturns {
    static let sourceBundleID = "com.academic-achievement.manager"
    static let targetBundleID = "com.gaoseries.GaoCaoZuo"
    private static let action = "ocr.files"
    private static let ticketLimit = 4096
    private static let ticketKeys: Set<String> = [
        "schemaVersion", "requestID", "action", "sourceBundleID", "targetBundleID", "requestManifestSHA256", "expiresAt"
    ]
    let root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/GaoSeries/GaoAction/OcrReturns-v1", isDirectory: true
    )) {
        self.root = root
    }

    static func ticket(for request: GaoActionManifest, data: Data, now: Date) throws -> ResearchOCRReturnTicket {
        try GaoActionPackageValidator(expectedTargetBundleID: targetBundleID, now: now).validateManifest(request)
        guard request.kind == "request", request.sourceBundleID == sourceBundleID, request.action == action else {
            throw ResearchExchangeClientError.resultMismatch
        }
        return .init(schemaVersion: 1, requestID: request.requestID, action: action, sourceBundleID: sourceBundleID,
                     targetBundleID: targetBundleID, requestManifestSHA256: sha256(data), expiresAt: request.expiresAt)
    }

    func publish(_ ticket: ResearchOCRReturnTicket, now: Date) throws {
        guard Self.current(ticket, now: now), let slot = Self.slotName(ticket.requestID) else { throw GaoActionError.expired }
        let parent = try openMailbox(create: true)
        defer { close(parent) }
        guard mkdirat(parent, slot, 0o700) == 0 else {
            throw errno == EEXIST ? GaoActionError.packageAlreadyExists : GaoActionError.ioFailure
        }
        let directory = try GaoSecureFD.openChildDirectory(at: parent, name: slot, owned: true)
        defer { close(directory) }
        try Self.checkName(directory, slot)
        try GaoSecureFD.checkPrivatePermissions(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(ticket)
        let temporary = ".ticket-" + UUID().uuidString
        let file = try GaoSecureFD.createFile(at: directory, name: temporary)
        defer { close(file); unlinkat(directory, temporary, 0) }
        try GaoSecureFD.writeAll(bytes, to: file)
        guard fsync(file) == 0,
              renameatx_np(directory, temporary, directory, "request.json", UInt32(RENAME_EXCL)) == 0 else {
            throw GaoActionError.ioFailure
        }
        guard fsync(directory) == 0, fsync(parent) == 0 else {
            unlinkat(directory, "request.json", 0)
            throw GaoActionError.ioFailure
        }
    }

    func stageResult(for ticket: ResearchOCRReturnTicket, now: Date, stagingRoot: URL,
                     checkManifest: (GaoActionManifest) throws -> Void) throws -> GaoValidatedActionPackage? {
        guard Self.current(ticket, now: now), let slot = Self.slotName(ticket.requestID) else { return nil }
        let parent = try openMailbox(create: false)
        guard parent >= 0 else { return nil }
        defer { close(parent) }
        let directory = try GaoSecureFD.openChildDirectory(at: parent, name: slot, owned: true, allowMissing: true)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        try Self.checkName(directory, slot)
        try GaoSecureFD.checkPrivatePermissions(directory)
        let package = try GaoSecureFD.openChildDirectory(at: directory, name: "result.gaoaction", owned: true, allowMissing: true)
        guard package >= 0 else { return nil }
        defer { close(package) }
        try Self.checkName(package, "result.gaoaction")
        try GaoSecureFD.checkPrivatePermissions(package)
        let file = try GaoSecureFD.openRegularFile(at: directory, name: "request.json")
        defer { close(file) }
        try Self.checkName(file, "request.json")
        let before = try GaoSecureFD.stat(file)
        guard before.st_mode & 0o077 == 0 else { throw GaoActionError.permissionDenied }
        let data = try GaoSecureFD.readBounded(file, maximum: Self.ticketLimit)
        guard !data.starts(with: [0xef, 0xbb, 0xbf]), String(data: data, encoding: .utf8) != nil else {
            throw GaoActionError.invalidManifest
        }
        try GaoUniqueJSONKeys.validate(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Self.ticketKeys,
              let actual = try? JSONDecoder().decode(ResearchOCRReturnTicket.self, from: data), actual == ticket,
              GaoSecureFD.unchanged(before, try GaoSecureFD.stat(file)) else {
            throw ResearchExchangeClientError.resultMismatch
        }
        return try GaoActionPackageValidator(expectedTargetBundleID: Self.sourceBundleID, now: now)
            .stagePackage(in: package, stagingRoot: stagingRoot, requirePrivate: true, checkManifest: checkManifest)
    }

    private func openMailbox(create: Bool) throws -> Int32 {
        let actionURL = root.deletingLastPathComponent()
        let seriesURL = actionURL.deletingLastPathComponent()
        let fd: Int32
        if root.lastPathComponent == "OcrReturns-v1", actionURL.lastPathComponent == "GaoAction",
           seriesURL.lastPathComponent == "GaoSeries" {
            let series = try GaoSecureFD.openDirectory(seriesURL, requireOwnedFinal: true, create: create, allowMissing: !create)
            guard series >= 0 else { return -1 }
            defer { close(series) }
            try Self.checkName(series, "GaoSeries")
            guard try GaoSecureFD.stat(series).st_mode & 0o022 == 0 else { throw GaoActionError.permissionDenied }
            let action = try Self.mailboxChild(series, name: "GaoAction", create: create)
            guard action >= 0 else { return -1 }
            defer { close(action) }
            try Self.checkName(action, "GaoAction")
            guard try GaoSecureFD.stat(action).st_mode & 0o022 == 0 else { throw GaoActionError.permissionDenied }
            fd = try Self.mailboxChild(action, name: "OcrReturns-v1", create: create)
        } else {
            // The exchange fixtures may inject their own isolated mailbox root.
            fd = try GaoSecureFD.openDirectory(root, requireOwnedFinal: true, create: create, allowMissing: !create)
        }
        guard fd >= 0 else { return -1 }
        do {
            try Self.checkName(fd, root.lastPathComponent)
            try GaoSecureFD.checkPrivatePermissions(fd)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func mailboxChild(_ parent: Int32, name: String, create: Bool) throws -> Int32 {
        if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw GaoActionError.permissionDenied }
        return try GaoSecureFD.openChildDirectory(at: parent, name: name, owned: true, allowMissing: !create)
    }

    private static func checkName(_ descriptor: Int32, _ expected: String) throws {
        // A case-insensitive filesystem can resolve differently spelled aliases.
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let loaded = path.withUnsafeMutableBufferPointer {
            fcntl(descriptor, F_GETPATH, UnsafeMutableRawPointer($0.baseAddress!))
        }
        guard loaded == 0, let actual = String(validatingUTF8: path),
              URL(fileURLWithPath: actual).lastPathComponent == expected else { throw GaoActionError.unsafePath }
    }

    static func bind(_ result: GaoActionManifest, to request: GaoActionManifest,
                     ticket: ResearchOCRReturnTicket) throws {
        guard result.kind == "result", let reply = result.inReplyTo, reply == request.requestID,
              let resultID = UUID(uuidString: result.requestID), resultID != UUID(uuidString: request.requestID),
              result.sourceBundleID == request.targetBundleID, result.targetBundleID == request.sourceBundleID,
              result.action == request.action, result.parameters.isEmpty,
              result.provenance?["requestManifestSHA256"] == .string(ticket.requestManifestSHA256),
              let requestedAt = GaoActionISO8601.date(request.createdAt), let returnedAt = GaoActionISO8601.date(result.createdAt),
              returnedAt >= requestedAt, ["completed", "partial"].contains(result.status ?? ""), !result.items.isEmpty else {
            throw ResearchExchangeClientError.resultMismatch
        }
    }

    private static func current(_ ticket: ResearchOCRReturnTicket, now: Date) -> Bool {
        guard ticket.schemaVersion == 1, ticket.action == action, ticket.sourceBundleID == sourceBundleID,
              ticket.targetBundleID == targetBundleID, let expires = GaoActionISO8601.date(ticket.expiresAt) else { return false }
        return expires > now && expires.timeIntervalSince(now) <= GaoActionLimits.default.ttl + 0.001
    }

    static func slotName(_ requestID: String) -> String? {
        guard let id = UUID(uuidString: requestID), id.uuidString.caseInsensitiveCompare(requestID) == .orderedSame else { return nil }
        return id.uuidString.lowercased()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
