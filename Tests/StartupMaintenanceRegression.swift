import CryptoKit
import Foundation

/// CLI-only, isolated tests of the actual backup worker and readiness recorder.
/// Compile with production Sources (including the real repository/model decoder).
/// This never constructs PaperStore, NSApplication or a production data root.
#if !RESEARCH_INTEGRATION_COMBINED
@main
#endif
enum StartupMaintenanceRegression {
    struct Failed: Error { let message: String }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failed(message: message) }
    }
    static func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    static func main() async throws {
        guard let raw = ProcessInfo.processInfo.environment["GAO_STARTUP_REGRESSION_ROOT"],
              raw.hasPrefix("/private/tmp/"), raw.contains(".noindex/"),
              ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"]?.hasPrefix(raw) == true else {
            throw Failed(message: "Isolated private noindex fixture root and data override required")
        }
        let root = URL(fileURLWithPath: raw, isDirectory: true)
        let fm = FileManager.default
        try require(!fm.fileExists(atPath: root.path), "Fixture root must be new")
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let library = try encoder.encode(PersistedLibrary(version: LibrarySchema.currentVersion))
        func fixture(_ name: String) throws -> AutomaticBackupWorker.Plan {
            let base = root.appendingPathComponent(name, isDirectory: true)
            let source = base.appendingPathComponent("Data", isDirectory: true)
            try fm.createDirectory(at: source.appendingPathComponent("Attachments/record", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: source.appendingPathComponent("EmptyDirectory", isDirectory: true), withIntermediateDirectories: true)
            try library.write(to: source.appendingPathComponent("library.json"))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.appendingPathComponent("library.json").path)
            try Data((0..<262144).map { UInt8($0 % 251) }).write(to: source.appendingPathComponent("Attachments/record/file.bin"))
            try Data("private hidden metadata".utf8).write(to: source.appendingPathComponent(".preserved"))
            return .init(source: source, destination: base.appendingPathComponent("Backups/today.gaoyanjiu"), appVersion: "fixture", libraryVersion: LibrarySchema.currentVersion)
        }
        func run(_ plan: AutomaticBackupWorker.Plan, hook: (() throws -> Void)? = nil) async throws -> AutomaticBackupWorker.Outcome {
            try await Task.detached { try AutomaticBackupWorker.run(plan, afterCopy: hook) }.value
        }
        func addDeclaredPayloads(_ plan: AutomaticBackupWorker.Plan) throws {
            let stamp = Date(timeIntervalSince1970: 1_700_000_000)
            let attachment = WorkAttachment(id: "work-attachment", originalName: "file.bin", storedName: "file.bin", kind: "file", addedAt: stamp)
            let work = ExistingWork(id: "record", title: "Synthetic", type: .journalArticle, venue: "", authors: "", completedAt: stamp,
                identifier: "", url: "", notes: "", attachments: [attachment], createdAt: stamp, updatedAt: stamp,
                patentType: nil, journalISSN: nil, journalMetrics: nil, authorPosition: nil)
            let certificateAttachment = WorkAttachment(id: "certificate-attachment", originalName: "cert.bin", storedName: "cert.bin", kind: "file", addedAt: stamp)
            let certificate = CertificateRecord(id: "certificate", name: "Synthetic", eventDate: stamp, tags: [],
                attachments: [certificateAttachment], createdAt: stamp, updatedAt: stamp)
            let folder = DocumentFolder(id: "folder", libraryKind: .experimentData, name: "Synthetic", createdAt: stamp, updatedAt: stamp)
            let document = ManagedDocument(id: "document", folderID: folder.id, originalName: "doc.txt", displayName: "Synthetic", storedName: "doc.txt",
                fileExtension: "txt", tags: [], byteCount: 3, uploadedAt: stamp, updatedAt: stamp)
            let trash: [TrashItem] = [
                .init(id: "trash-work", kind: .work, title: "", deletedAt: stamp, work: work),
                .init(id: "trash-certificate", kind: .certificate, title: "", deletedAt: stamp, certificate: certificate),
                .init(id: "trash-folder", kind: .documentFolder, title: "", deletedAt: stamp, documentFolder: folder, documents: [document]),
                .init(id: "trash-document", kind: .document, title: "", deletedAt: stamp, documents: [document]),
                .init(id: "trash-work-attachment", kind: .workAttachment, title: "", deletedAt: stamp, attachment: attachment, parentID: work.id),
                .init(id: "trash-certificate-attachment", kind: .certificateAttachment, title: "", deletedAt: stamp, attachment: certificateAttachment, parentID: certificate.id)
            ]
            let files: [String: Data] = [
                "CertificateAttachments/certificate/cert.bin": Data("cert".utf8),
                "ManagedDocuments/experimentData/folder/doc.txt": Data("doc".utf8),
                "TrashStorage/trash-work/payload/file.bin": try bytes(plan.source.appendingPathComponent("Attachments/record/file.bin")),
                "TrashStorage/trash-certificate/payload/cert.bin": Data("cert".utf8),
                "TrashStorage/trash-folder/payload/doc.txt": Data("doc".utf8),
                "TrashStorage/trash-document/payload": Data("doc".utf8),
                "TrashStorage/trash-work-attachment/payload": Data("work".utf8),
                "TrashStorage/trash-certificate-attachment/payload": Data("cert".utf8)
            ]
            for (relative, data) in files {
                let url = plan.source.appendingPathComponent(relative)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            try encoder.encode(PersistedLibrary(existingWorks: [work], certificates: [certificate], documentFolders: [folder], managedDocuments: [document], trashItems: trash))
                .write(to: plan.source.appendingPathComponent("library.json"))
        }
        func rejects(_ name: String, _ plan: AutomaticBackupWorker.Plan, hook: (() throws -> Void)? = nil) async throws {
            do { _ = try await run(plan, hook: hook); throw Failed(message: "Unexpected success: " + name) }
            catch is Failed { throw Failed(message: "Expected worker refusal: " + name) }
            catch { try require(!fm.fileExists(atPath: plan.destination.path), "Failure published daily archive: " + name) }
            let parent = plan.destination.deletingLastPathComponent()
            if fm.fileExists(atPath: parent.path) {
                try require(fm.contentsOfDirectory(atPath: parent.path).allSatisfy { !$0.contains(".partial-") }, "Partial archive not cleaned: " + name)
            }
            print("PASS " + name)
        }

        let success = try fixture("complete")
        try addDeclaredPayloads(success)
        let created = try await run(success)
        try require(created == .created, "Worker must create verified archive")
        let originalArchive = try bytes(success.destination)
        let extract = root.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extract, withIntermediateDirectories: true)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", success.destination.path, extract.path]
        try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == 0, "Archive extraction failed")
        let extractedRoot = extract.appendingPathComponent("GaoResearchBackup", isDirectory: true)
        // ditto without --keepParent may place the payload contents at extraction root.
        let payload = fm.fileExists(atPath: extractedRoot.path) ? extractedRoot : extract
        let extracted = payload.appendingPathComponent("AcademicAchievementManager", isDirectory: true)
        try require(AutomaticBackupWorker.inventory(extracted) == AutomaticBackupWorker.inventory(success.source), "Restored file/empty-directory manifest differs")
        let manifest = try JSONSerialization.jsonObject(with: bytes(payload.appendingPathComponent("manifest.json"))) as! [String: Any]
        let expectedFiles = try AutomaticBackupWorker.inventory(success.source).compactMapValues(\.digest)
        try require(manifest["files"] as? [String: String] == expectedFiles, "Archive lacks complete digest manifest")
        print("PASS background complete snapshot and restore digest verification")

        // An already completed day never overwrites the archive after new user edits.
        try Data("edited after backup".utf8).write(to: success.source.appendingPathComponent("Attachments/record/file.bin"))
        let repeated = try await run(success)
        try require(repeated == .alreadyExistsNotRevalidated, "Second call is not idempotent")
        try require(bytes(success.destination) == originalArchive, "Existing valid backup changed")
        print("PASS same-day idempotence preserves earlier archive")

        let drift = try fixture("drift")
        try await rejects("concurrent same-length attachment mutation refuses publication", drift, hook: {
            try Data(repeating: 17, count: 262144).write(to: drift.source.appendingPathComponent("Attachments/record/file.bin"))
        })
        let missing = try fixture("missing")
        try await rejects("attachment disappearing during snapshot is not empty data", missing, hook: {
            try fm.removeItem(at: missing.source.appendingPathComponent("Attachments/record/file.bin"))
        })
        let declaredMissing = try fixture("declared-missing")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        var declared = PersistedLibrary(version: LibrarySchema.currentVersion)
        declared.certificates = [CertificateRecord(id: "certificate", name: "Synthetic", eventDate: stamp, tags: [],
            attachments: [WorkAttachment(id: "missing", originalName: "missing.pdf", storedName: "missing.pdf", kind: "pdf", addedAt: stamp)],
            createdAt: stamp, updatedAt: stamp)]
        try encoder.encode(declared).write(to: declaredMissing.source.appendingPathComponent("library.json"))
        try await rejects("initially missing declared attachment refuses complete backup", declaredMissing)
        let trashMissing = try fixture("trash-declared-missing")
        try addDeclaredPayloads(trashMissing)
        try fm.removeItem(at: trashMissing.source.appendingPathComponent("TrashStorage/trash-document/payload"))
        try await rejects("initially missing declared trash payload refuses complete backup", trashMissing)
        let corrupt = try fixture("corrupt")
        try Data("{}".utf8).write(to: corrupt.source.appendingPathComponent("library.json"))
        try await rejects("invalid current library does not create a zero-record backup", corrupt)
        let future = try fixture("future")
        try encoder.encode(PersistedLibrary(version: LibrarySchema.currentVersion + 1)).write(to: future.source.appendingPathComponent("library.json"))
        try await rejects("future schema remains untouched and unbacked", future)
        let linked = try fixture("linked")
        try fm.createSymbolicLink(at: linked.source.appendingPathComponent("link"), withDestinationURL: success.source)
        try await rejects("symlink payload is refused without following it", linked)

        let preserve = try fixture("preserve")
        let history = preserve.destination.deletingLastPathComponent().appendingPathComponent("earlier.gaoyanjiu")
        try fm.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try originalArchive.write(to: history)
        try Data("unreadable structure".utf8).write(to: preserve.source.appendingPathComponent("library.json"))
        try await rejects("failed attempt never rotates previous history", preserve)
        try require(bytes(history) == originalArchive, "Failure modified earlier backup")

        ResearchStartupDiagnostics.mark("content-first-appeared")
        func phases() throws -> [String] {
            let events = try JSONSerialization.jsonObject(with: ResearchStartupDiagnostics.snapshot()) as! [[String: Any]]
            return events.compactMap { $0["phase"] as? String }
        }
        try require(!phases().contains("startup-data-ready"), "Blank window reported ready")
        ResearchStartupDiagnostics.mark("library-read-ready")
        ResearchStartupDiagnostics.mark("widget-publication-pending")
        try require(!phases().contains("startup-data-ready"), "Pending widget reported ready")
        ResearchStartupDiagnostics.mark("widget-publication-ready")
        try require(phases().filter { $0 == "startup-data-ready" }.count == 1, "Full readiness event missing")
        ResearchStartupDiagnostics.mark("content-first-appeared")
        try require(phases().filter { $0 == "startup-data-ready" }.count == 1, "Readiness duplicated on window reopen")
        print("PASS DataReady requires loaded data + successful widget publication + real content appearance")
        print("Startup maintenance isolated regression complete; no application or smoke test launched.")
    }
}
