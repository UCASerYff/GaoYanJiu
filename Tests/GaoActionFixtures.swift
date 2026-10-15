import Foundation
import CryptoKit
import Darwin

/// Shared V1 fixture names, clock, UUIDs and nonce prescribed by the handoff contract.
/// These fixtures are test data only; production writers always create a new nonce and lifetime.
enum GaoActionFixtures {
    static let names = ["v1-documents-newText", "v1-storage-directory", "v1-ocr-partial", "v1-duplicate-request",
                        "v1-expired", "v1-path-traversal", "v1-unknown-action", "v2-unsupported"]
    static let now = GaoActionISO8601.date("2026-10-12T12:00:00Z")!
    static let nonce = Data(repeating: 0, count: 32).base64EncodedString()
    static let hello = Data("hello\n".utf8)
    static let helloSHA = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
    static let researchID = "com.academic-achievement.manager"
    static func requestID(_ index: Int) -> String { String(format: "11111111-1111-4111-8111-%012d", index + 1) }
    static func manifest(_ index: Int, directory: URL) throws -> GaoActionManifest {
        var value = GaoActionManifest(requestID: requestID(index), sourceBundleID: researchID,
                                      targetBundleID: researchID, action: "research.importDocuments",
                                      createdAt: "2026-10-12T12:00:00Z", expiresAt: "2026-10-12T12:02:00Z", nonce: nonce,
                                      items: [.init(id: "input", relativePath: "payload/input.txt", uti: "public.utf8-plain-text", byteCount: 6, sha256: helloSHA)])
        switch index {
        case 0:
            value.targetBundleID = "com.gaoseries.GaoWenJian"; value.action = "documents.newText"
            value.parameters = ["suggestedTitle": .string("交接测试")]
        case 1:
            value.targetBundleID = "com.gaoseries.GaoJiLing"; value.action = "storage.inspect"; value.items = []
            value.references = [try GaoActionReference.capture(at: directory, kind: "directory", displayName: "Fixture directory")]
        case 2:
            value.kind = "result"; value.sourceBundleID = "com.gaoseries.GaoJieTu"; value.action = "ocr.files"
            value.inReplyTo = requestID(index); value.status = "partial"
            value.provenance = ["sourceItemID": .string("scan"), "sourceSHA256": .string(helloSHA),
                "engine": .string("fixture-local"), "engineVersion": .string("1"), "languages": .array([.string("zh-Hans")]),
                "pages": .array([.object(["pageNumber": .number(1), "status": .string("completed")]),
                                 .object(["pageNumber": .number(2), "status": .string("failed"), "errorCode": .string("fixture-page-failure")])])]
        case 3: break // The same valid request is presented twice to the durable importer ledger.
        case 4: value.createdAt = "2026-10-12T11:57:00Z"; value.expiresAt = "2026-10-12T11:59:00Z"
        case 5: value.items[0].relativePath = "payload/../escape.txt"
        case 6: value.action = "research.executeShell"
        case 7: value.schemaVersion = 2
        default: preconditionFailure("Unknown fixed fixture")
        }
        return value
    }
    @discardableResult
    static func makePackage(_ manifest: GaoActionManifest, in root: URL, name: String, files: [String: Data] = ["payload/input.txt": hello]) throws -> URL {
        let url = root.appendingPathComponent(name + ".gaoaction", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("payload", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        for (relativePath, data) in files {
            let target = url.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let file = url.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return url
    }
}

#if !GAO_FIXTURES_LIBRARY
@main
struct GaoActionFixtureTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "GaoActionFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func test(_ name: String, _ body: () throws -> Void) throws {
        print("RUN \(name)"); try body(); passed += 1; print("PASS \(name)")
    }
    static func rejects(_ expected: Set<GaoActionError>, _ body: () throws -> Void) throws {
        do { try body() }
        catch let error as GaoActionError {
            try check(expected.contains(error), "Unexpected rejection: \(error)")
            return
        }
        throw NSError(domain: "GaoActionFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsafe input was accepted"])
    }
    static func main() throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/research-exchange-tests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let staging = root.appendingPathComponent("Receiver/Staging", isDirectory: true)
        let fixtureDirectory = root.appendingPathComponent("SelectedDirectory", isDirectory: true)
        try fm.createDirectory(at: fixtureDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        try check(SHA256.hash(data: GaoActionFixtures.hello).map({ String(format: "%02x", $0) }).joined() == GaoActionFixtures.helloSHA, "Fixed hello SHA differs")
        for index in 0..<GaoActionFixtures.names.count {
            try test(GaoActionFixtures.names[index]) {
                let manifest = try GaoActionFixtures.manifest(index, directory: fixtureDirectory)
                let package = try GaoActionFixtures.makePackage(manifest, in: root, name: GaoActionFixtures.names[index])
                let validator = GaoActionPackageValidator(expectedTargetBundleID: manifest.targetBundleID, now: GaoActionFixtures.now)
                if index < 4 {
                    let accepted = try validator.stagePackage(at: package, stagingRoot: staging)
                    try check(accepted.manifest.requestID == GaoActionFixtures.requestID(index), "Wrong fixture UUID")
                    try check(accepted.manifest.nonce == GaoActionFixtures.nonce, "Wrong fixture nonce")
                    if index == 0 { try check(try Data(contentsOf: accepted.stagedItems[0].url) == GaoActionFixtures.hello, "hello copy mismatch") }
                    if index == 1 {
                        try check(accepted.manifest.references[0].declaredIdentity.inode != nil, "Identity not captured")
                        try check(accepted.stagedItems.isEmpty, "Directory reference became a file copy")
                    }
                    if index == 2 { try check(accepted.manifest.status == "partial" && accepted.manifest.inReplyTo == GaoActionFixtures.requestID(2), "Partial result not mapped") }
                    if index == 3 {
                        let retry = try validator.stagePackage(at: package, stagingRoot: staging)
                        try check(retry.manifest.requestID == accepted.manifest.requestID, "Duplicate request identity changed")
                        // Approval/side-effect suppression belongs to the durable importer ledger, not this transport.
                    }
                } else {
                    let expected: [GaoActionError] = [.expired, .unsafePath, .unknownAction, .unsupportedVersion]
                    try rejects([expected[index - 4]]) { _ = try validator.stagePackage(at: package, stagingRoot: staging) }
                }
            }
        }
        let base = try GaoActionFixtures.manifest(3, directory: fixtureDirectory)
        let validator = GaoActionPackageValidator(expectedTargetBundleID: GaoActionFixtures.researchID, now: GaoActionFixtures.now)
        try test("request-target-kind-nonce-result-binding") {
            var m = base; m.targetBundleID = "com.example.Other"
            try rejects([.wrongTarget]) { try validator.validateManifest(m) }
            m = base; m.kind = "command"
            try rejects([.invalidManifest]) { try validator.validateManifest(m) }
            m = base; m.nonce = Data(repeating: 0, count: 31).base64EncodedString()
            try rejects([.invalidNonce]) { try validator.validateManifest(m) }
            m = base; m.kind = "result"; m.status = "completed"; m.provenance = [:]
            try rejects([.invalidManifest]) { try validator.validateManifest(m) }
            m.inReplyTo = "not-a-uuid"
            try rejects([.invalidManifest]) { try validator.validateManifest(m) }
            m.inReplyTo = base.requestID; m.status = "opened"
            try rejects([.invalidManifest]) { try validator.validateManifest(m) }
            m.status = "pending"; m.provenance = ["workflowState": .string("awaitingUser")]
            try validator.validateManifest(m)
        }
        try test("parameter-white-lists-and-source-is-only-a-declaration") {
            var m = base; m.parameters = ["targetRecordID": .string("fixture-target")]
            try validator.validateManifest(m)
            m.sourceBundleID = "com.example.UntrustedSender"
            try validator.validateManifest(m)
            m.parameters["shell"] = .string("not executable")
            try rejects([.invalidParameters]) { try validator.validateManifest(m) }
            m = base; m.parameters = ["targetRecordID": .bool(true)]
            try rejects([.invalidParameters]) { try validator.validateManifest(m) }
            m = base; m.kind = "result"; m.inReplyTo = base.requestID; m.status = "completed"; m.provenance = ["nested": .object(["callbackURL": .string("test")])]
            try rejects([.invalidParameters]) { try validator.validateManifest(m) }
        }
        try test("reference-canonical-url-does-not-authorize-access") {
            var m = try GaoActionFixtures.manifest(1, directory: fixtureDirectory)
            m.references[0].fileURL = "https://example.invalid/private"
            let v = GaoActionPackageValidator(expectedTargetBundleID: m.targetBundleID, now: GaoActionFixtures.now)
            try rejects([.invalidReference]) { try v.validateManifest(m) }
            m.references[0].fileURL = "file:///private/tmp/a/../b"
            try rejects([.invalidReference]) { try v.validateManifest(m) }
            m.references[0].fileURL = "file:///private/tmp/nonexistent-reference-fixture"
            m.references[0].declaredIdentity = .init()
            try v.validateManifest(m) // Receiver must independently reselect/verify this declaration before use.
        }
        try test("manifest-and-item-count-and-total-payload-bounds") {
            try rejects([.manifestTooLarge]) { _ = try validator.validateManifestData(Data(repeating: 0x20, count: 1_048_577)) }
            var m = base
            m.items = (0..<257).map { .init(id: "item-\($0)", relativePath: "payload/item-\($0).txt", uti: "public.plain-text", byteCount: 0, sha256: GaoActionFixtures.helloSHA) }
            try rejects([.tooManyItems]) { try validator.validateManifest(m) }
            m.items.removeLast(); try validator.validateManifest(m)
            m = base; m.items[0].byteCount = 2_147_483_649
            try rejects([.payloadTooLarge]) { try validator.validateManifest(m) }
            m.items[0].byteCount = Int64.max
            m.items.append(.init(id: "next", relativePath: "payload/next.txt", uti: "public.plain-text", byteCount: 6, sha256: GaoActionFixtures.helloSHA))
            try rejects([.payloadTooLarge]) { try validator.validateManifest(m) }
        }
        try test("unsafe-relative-paths") {
            for path in ["/payload/input.txt", "payload/../input.txt", "payload/a/../../input.txt", "payload/./input.txt", "payload//input.txt", "payload\\input.txt", "payload/input\u{0}.txt"] {
                var m = base; m.items[0].relativePath = path
                try rejects([.unsafePath]) { try validator.validateManifest(m) }
            }
        }
        try test("payload-and-intermediate-directory-symlinks") {
            let package = try GaoActionFixtures.makePackage(base, in: root, name: "symlink-file")
            let file = package.appendingPathComponent("payload/input.txt")
            try fm.removeItem(at: file); try fm.createSymbolicLink(at: file, withDestinationURL: fixtureDirectory)
            try rejects([.unsafePath, .unsafeFile]) { _ = try validator.stagePackage(at: package, stagingRoot: staging) }
            var m = base; m.items[0].relativePath = "payload/nested/input.txt"
            let nested = try GaoActionFixtures.makePackage(m, in: root, name: "symlink-directory", files: [:])
            try fm.createSymbolicLink(at: nested.appendingPathComponent("payload/nested"), withDestinationURL: fixtureDirectory)
            try rejects([.unsafePath]) { _ = try validator.stagePackage(at: nested, stagingRoot: staging) }
        }
        try test("package-ancestor-symlink-is-rejected") {
            let realParent = root.appendingPathComponent("RealPackageParent", isDirectory: true)
            let package = try GaoActionFixtures.makePackage(base, in: realParent, name: "ancestor")
            // A user directory named tmp is not the whitelisted root /tmp.
            let alias = root.appendingPathComponent("tmp", isDirectory: true)
            try fm.createSymbolicLink(at: alias, withDestinationURL: realParent)
            let linkedPackage = alias.appendingPathComponent(package.lastPathComponent, isDirectory: true)
            let stagedBefore = try fm.contentsOfDirectory(atPath: staging.path).count
            for path in [linkedPackage, GaoActionFileAccess.canonicalFileURL(linkedPackage)] {
                try rejects([.unsafePath]) { _ = try validator.stagePackage(at: path, stagingRoot: staging) }
            }
            try check(try fm.contentsOfDirectory(atPath: staging.path).count == stagedBefore, "Linked package created receiver staging")
            try check(try Data(contentsOf: package.appendingPathComponent("payload/input.txt")) == GaoActionFixtures.hello, "Linked package rejection changed source")
        }
        try test("own-staging-ancestor-symlink-is-rejected-before-creation") {
            let package = try GaoActionFixtures.makePackage(base, in: root, name: "safe-package-for-linked-staging")
            let realParent = root.appendingPathComponent("RealStagingParent", isDirectory: true)
            try fm.createDirectory(at: realParent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let alias = root.appendingPathComponent("LinkedStagingParent", isDirectory: true)
            try fm.createSymbolicLink(at: alias, withDestinationURL: realParent)
            let newStaging = alias.appendingPathComponent("Missing/Nested/Staging", isDirectory: true)
            try rejects([.unsafePath]) { _ = try validator.stagePackage(at: package, stagingRoot: newStaging) }
            try check(try fm.contentsOfDirectory(atPath: realParent.path).isEmpty, "Staging followed an ancestor link while creating directories")
            let existing = realParent.appendingPathComponent("Existing/Staging", isDirectory: true)
            try fm.createDirectory(at: existing, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try rejects([.unsafePath]) {
                _ = try validator.stagePackage(at: package, stagingRoot: alias.appendingPathComponent("Existing/Staging", isDirectory: true))
            }
            try check(try fm.contentsOfDirectory(atPath: existing.path).isEmpty, "Staging followed a link to an existing directory")
        }
        try test("writer-and-file-access-ancestor-symlinks-are-rejected") {
            let realParent = root.appendingPathComponent("RealWriterParent", isDirectory: true)
            try fm.createDirectory(at: realParent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let selected = realParent.appendingPathComponent("selected.txt")
            try GaoActionFixtures.hello.write(to: selected)
            let alias = root.appendingPathComponent("LinkedWriterParent", isDirectory: true)
            try fm.createSymbolicLink(at: alias, withDestinationURL: realParent)
            try rejects([.unsafePath]) { _ = try GaoActionFileAccess.fingerprint(at: alias.appendingPathComponent("selected.txt")) }
            try rejects([.unsafePath]) {
                _ = try GaoActionPackageWriter().write(manifest: base, files: ["input": selected],
                                                       outgoingRoot: alias.appendingPathComponent("Outgoing", isDirectory: true))
            }
            try rejects([.unsafePath]) {
                _ = try GaoActionFileAccess.copyRegularFile(at: selected, to: alias.appendingPathComponent("Copies/private.txt"))
            }
            try check(!fm.fileExists(atPath: realParent.appendingPathComponent("Outgoing").path) &&
                      !fm.fileExists(atPath: realParent.appendingPathComponent("Copies").path), "Safe writer created files through an ancestor link")
            try check(try Data(contentsOf: selected) == GaoActionFixtures.hello, "Ancestor rejection changed selected source")
        }
        try test("macos-root-aliases-work-without-resolving-user-links") {
            for (alias, actual) in [("/tmp", "/private/tmp"), ("/var", "/private/var"), ("/etc", "/private/etc")] {
                let declared = try GaoActionReference.capture(at: URL(fileURLWithPath: alias, isDirectory: true), kind: "directory")
                let direct = try GaoActionReference.capture(at: URL(fileURLWithPath: actual, isDirectory: true), kind: "directory")
                try check(declared.declaredIdentity.device == direct.declaredIdentity.device &&
                          declared.declaredIdentity.inode == direct.declaredIdentity.inode, "System root alias resolved to a different directory")
            }
            try check(GaoActionFileAccess.canonicalFileURL(URL(fileURLWithPath: "/private/tmp")).path == "/private/tmp", "Lexical normalization rewrote private prefix")
            let package = try GaoActionFixtures.makePackage(base, in: root, name: "tmp-alias-package")
            let aliasRoot = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(root.lastPathComponent, isDirectory: true)
            let accepted = try validator.stagePackage(at: aliasRoot.appendingPathComponent(package.lastPathComponent, isDirectory: true),
                                                       stagingRoot: aliasRoot.appendingPathComponent("AliasReceiver/Staging", isDirectory: true))
            try check(try Data(contentsOf: accepted.stagedItems[0].url) == GaoActionFixtures.hello, "Whitelisted /tmp alias could not stage a private copy")
        }
        try test("hardlinks-directories-and-fifos") {
            let package = try GaoActionFixtures.makePackage(base, in: root, name: "hardlink")
            let file = package.appendingPathComponent("payload/input.txt")
            try fm.linkItem(at: file, to: root.appendingPathComponent("other-hardlink.txt"))
            try rejects([.unsafeFile]) { _ = try validator.stagePackage(at: package, stagingRoot: staging) }
            let directoryPackage = try GaoActionFixtures.makePackage(base, in: root, name: "directory-item", files: [:])
            try fm.createDirectory(at: directoryPackage.appendingPathComponent("payload/input.txt"), withIntermediateDirectories: false)
            try rejects([.unsafeFile]) { _ = try validator.stagePackage(at: directoryPackage, stagingRoot: staging) }
            let fifoPackage = try GaoActionFixtures.makePackage(base, in: root, name: "fifo-item", files: [:])
            try check(mkfifo(fifoPackage.appendingPathComponent("payload/input.txt").path, 0o600) == 0, "Cannot make test FIFO")
            try rejects([.unsafeFile]) { _ = try validator.stagePackage(at: fifoPackage, stagingRoot: staging) }
        }
        try test("permissions-and-uid") {
            let package = try GaoActionFixtures.makePackage(base, in: root, name: "unreadable")
            let file = package.appendingPathComponent("payload/input.txt")
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            try rejects([.permissionDenied]) { _ = try validator.stagePackage(at: package, stagingRoot: staging) }
            if geteuid() != 0 {
                try rejects([.permissionDenied]) { _ = try GaoActionFileAccess.fingerprint(at: URL(fileURLWithPath: "/bin/ls")) }
            }
        }
        try test("digest-and-count-mismatch-do-not-leave-staging") {
            var m = base; m.items[0].sha256 = String(repeating: "0", count: 64)
            let package = try GaoActionFixtures.makePackage(m, in: root, name: "wrong-digest")
            let countBefore = (try? fm.contentsOfDirectory(atPath: staging.path).count) ?? 0
            try rejects([.checksumMismatch]) { _ = try validator.stagePackage(at: package, stagingRoot: staging) }
            try check((try fm.contentsOfDirectory(atPath: staging.path).count) == countBefore, "Failed staging was not removed")
            m = base; m.items[0].byteCount = 7
            let sized = try GaoActionFixtures.makePackage(m, in: root, name: "wrong-count")
            try rejects([.byteCountMismatch]) { _ = try validator.stagePackage(at: sized, stagingRoot: staging) }
        }
        try test("production-writer-private-permissions-random-nonce-and-copy") {
            let selected = root.appendingPathComponent("selected.txt")
            try GaoActionFixtures.hello.write(to: selected)
            let outgoing = root.appendingPathComponent("Outgoing", isDirectory: true)
            let package = try GaoActionPackageWriter().write(manifest: base, files: ["input": selected], outgoingRoot: outgoing)
            let decoded = try GaoActionPackageValidator(expectedTargetBundleID: base.targetBundleID).stagePackage(at: package, stagingRoot: staging)
            try check(decoded.manifest.nonce != GaoActionFixtures.nonce, "Production used fixture nonce")
            try check(Data(base64Encoded: decoded.manifest.nonce)?.count == 32, "Production nonce not 32 bytes")
            try check(decoded.manifest.createdAt != base.createdAt, "Production reused old clock")
            for (url, expected) in [(package, 0o700), (package.appendingPathComponent("payload"), 0o700), (package.appendingPathComponent("manifest.json"), 0o600), (package.appendingPathComponent("payload/input.txt"), 0o600)] {
                let mode = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
                try check(mode?.intValue == expected, "Wrong private permissions")
            }
            try check(try Data(contentsOf: selected) == GaoActionFixtures.hello, "Writer changed original")
            try rejects([.packageAlreadyExists]) { _ = try GaoActionPackageWriter().write(manifest: base, files: ["input": selected], outgoingRoot: outgoing) }
            let privateCopy = root.appendingPathComponent("Selections/private.txt")
            let copied = try GaoActionFileAccess.copyRegularFile(at: selected, to: privateCopy)
            try check(copied.sha256 == GaoActionFixtures.helloSHA, "Safe copy SHA mismatch")
            try rejects([.ioFailure]) { _ = try GaoActionFileAccess.copyRegularFile(at: selected, to: privateCopy) }
        }
        try test("writer-and-reader-aggregate-limits") {
            var limit = GaoActionLimits.default; limit.maximumPayloadBytes = 5
            let selected = root.appendingPathComponent("limited.txt"); try GaoActionFixtures.hello.write(to: selected)
            try rejects([.payloadTooLarge]) { _ = try GaoActionPackageWriter(limits: limit).write(manifest: base, files: ["input": selected], outgoingRoot: root.appendingPathComponent("LimitedOutgoing")) }
            let package = try GaoActionFixtures.makePackage(base, in: root, name: "limited-reader")
            try rejects([.payloadTooLarge]) { _ = try GaoActionPackageValidator(expectedTargetBundleID: base.targetBundleID, now: GaoActionFixtures.now, limits: limit).stagePackage(at: package, stagingRoot: staging) }
            let oversized = root.appendingPathComponent("oversized-sparse")
            fm.createFile(atPath: oversized.path, contents: nil)
            let handle = try FileHandle(forWritingTo: oversized); try handle.truncate(atOffset: 2_147_483_649); try handle.close()
            try rejects([.payloadTooLarge]) { _ = try GaoActionPackageWriter().write(manifest: base, files: ["input": oversized], outgoingRoot: root.appendingPathComponent("OversizedOutgoing")) }
        }
        try test("concurrent-source-mutation-is-rejected") {
            let package = try GaoActionFixtures.makePackage(base, in: root, name: "changing", files: [:])
            let source = package.appendingPathComponent("payload/input.txt")
            fm.createFile(atPath: source.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: source); try handle.truncate(atOffset: 64 * 1024 * 1024); try handle.close()
            let fingerprint = try GaoActionFileAccess.fingerprint(at: source)
            var m = base; m.items[0].byteCount = fingerprint.byteCount; m.items[0].sha256 = fingerprint.sha256
            try encoder.encode(m).write(to: package.appendingPathComponent("manifest.json"), options: .atomic)
            let fd = Darwin.open(source.path, O_WRONLY | O_CLOEXEC)
            try check(fd >= 0, "Cannot open mutation fixture")
            let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                var byte: UInt8 = 1
                for index in 0..<300 {
                    _ = pwrite(fd, &byte, 1, 0); byte = byte == 1 ? 2 : 1
                    if index == 0 { started.signal() }; usleep(1000)
                }
                close(fd); finished.signal()
            }
            started.wait()
            try rejects([.sourceChanged, .checksumMismatch, .byteCountMismatch]) { _ = try validator.stagePackage(at: package, stagingRoot: staging) }
            finished.wait()
        }
        print("GaoAction V1 transport: \(passed) checks passed; durable duplicate suppression is exercised by importer integration tests.")
    }
}
#endif
