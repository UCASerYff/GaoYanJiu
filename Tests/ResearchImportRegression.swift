import CryptoKit
import Darwin
import Foundation

@MainActor
@main struct ResearchImportRegression {
    struct Failure: Error, CustomStringConvertible { var description: String }
    struct Record: Codable, Equatable {
        var id: String
        var scopeID: String
        var relativePath: String
        var sha256: String
        var indexedText: String? = nil
    }
    struct Library: Codable {
        var version = 32
        var managedDocuments: [Record] = []
        var originalBusinessAndGameState = "papers/projects/funding/rewardCity unchanged"
    }
    struct Counters: Codable { var commits = 0; var indexes = 0 }

    @MainActor final class Fixture {
        let root: URL
        let libraryURL: URL
        let attachments: URL
        let exchange: URL
        var failCommit = false
        var failIndex = false
        var failAfterDurableCommit = false
        init(root: URL, initialize: Bool = true) throws {
            self.root = root
            libraryURL = root.appendingPathComponent("library.json")
            attachments = root.appendingPathComponent("ManagedDocuments", isDirectory: true)
            exchange = root.appendingPathComponent("Exchange", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if initialize { try save(Library()); try saveCounters(Counters()) }
        }
        func library() throws -> Library { try JSONDecoder().decode(Library.self, from: Data(contentsOf: libraryURL)) }
        func save(_ value: Library) throws { try JSONEncoder().encode(value).write(to: libraryURL, options: .atomic) }
        func counters() throws -> Counters {
            try JSONDecoder().decode(Counters.self, from: Data(contentsOf: root.appendingPathComponent("counters.json")))
        }
        func saveCounters(_ value: Counters) throws {
            try JSONEncoder().encode(value).write(to: root.appendingPathComponent("counters.json"), options: .atomic)
        }
        func engine(fault: ((ResearchImportJournal.FaultPoint) throws -> Void)? = nil,
                    progress: ((ImportJob.Stage, Int, Int) -> Void)? = nil) throws -> ResearchImportJournal {
            try ResearchImportJournal(exchangeRoot: exchange, attachmentsRoot: attachments, adapter: .init(
                currentRecords: {
                    try self.library().managedDocuments.map { record in
                        let bytes = try Data(contentsOf: self.attachments.appendingPathComponent(record.relativePath))
                        guard Self.sha(bytes) == record.sha256 else { throw Failure(description: "Fixture record attachment mismatch") }
                        return .init(documentID: record.id, scopeID: record.scopeID, sha256: record.sha256,
                                     destinationRelativePath: record.relativePath)
                    }
                }, commitRecords: { items in
                    if self.failCommit { throw Failure(description: "Injected atomic JSON save failure") }
                    var library = try self.library()
                    for item in items {
                        let record = try JSONDecoder().decode(Record.self, from: item.recordData)
                        try expect(record.id == item.documentID, "Opaque record payload changed")
                        try expect(!library.managedDocuments.contains(where: { $0.id == record.id }), "Duplicate record commit")
                        library.managedDocuments.append(record)
                    }
                    try self.save(library)
                    var counts = try self.counters(); counts.commits += 1; try self.saveCounters(counts)
                    if self.failAfterDurableCommit { throw Failure(description: "Injected failure after durable JSON save") }
                }, indexDocuments: { ids in
                    if self.failIndex { throw Failure(description: "Injected index failure") }
                    var library = try self.library()
                    for offset in library.managedDocuments.indices where ids.contains(library.managedDocuments[offset].id) {
                        let file = self.attachments.appendingPathComponent(library.managedDocuments[offset].relativePath)
                        library.managedDocuments[offset].indexedText = try String(contentsOf: file, encoding: .utf8)
                    }
                    try self.save(library)
                    var counts = try self.counters(); counts.indexes += 1; try self.saveCounters(counts)
                }), failureInjector: fault, progress: progress)
        }
        func inputs(_ texts: [String] = ["first fixture", "second fixture"], variant: String = "initial") throws -> [ResearchImportJournal.Input] {
            let incoming = root.appendingPathComponent("Incoming/" + variant, isDirectory: true)
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            return try texts.enumerated().map { offset, text in
                let data = Data(text.utf8), id = "doc-\(variant)-\(offset)"
                let source = incoming.appendingPathComponent("\(offset).txt")
                try data.write(to: source)
                let record = Record(id: id, scopeID: "fixture-folder", relativePath: "summaryReports/fixture-folder/\(id).txt", sha256: Self.sha(data))
                return .init(id: "item-\(offset)", sourceURL: source, documentID: id, scopeID: record.scopeID,
                             destinationRelativePath: record.relativePath, sha256: record.sha256, byteCount: Int64(data.count),
                             recordData: try JSONEncoder().encode(record),
                             provenance: .init(documentID: id, originalSHA256: record.sha256,
                                               sourceBundleID: "com.gao.research.fixture", sourceDeclaration: "fixture only"))
            }
        }
        func managedFiles() throws -> [String] {
            guard let enumerator = FileManager.default.enumerator(at: attachments, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
            return try enumerator.compactMap { value -> String? in
                guard let url = value as? URL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
                return url.lastPathComponent
            }.sorted()
        }
        static func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    }

    static func expect(_ condition: Bool, _ description: String) throws {
        if !condition { throw Failure(description: description) }
    }
    static func rejected(_ description: String, _ body: () async throws -> Void) async throws {
        var failed = false
        do { try await body() } catch { failed = true }
        try expect(failed, description)
    }
    static func checkComplete(_ fixture: Fixture, count: Int) throws {
        let library = try fixture.library()
        try expect(library.managedDocuments.count == count, "Wrong durable record count")
        try expect(Set(library.managedDocuments.map(\.id)).count == count, "Duplicate durable IDs")
        try expect(library.originalBusinessAndGameState == Library().originalBusinessAndGameState, "Unrelated business/game data changed")
        try expect(library.managedDocuments.allSatisfy { $0.indexedText != nil }, "Index and records disagree")
        try expect(try fixture.managedFiles().count == count, "Untracked attachment files")
    }
    static func treeHashes(_ root: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var hashes: [String: String] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            hashes[String(url.path.dropFirst(root.path.count))] = Fixture.sha(try Data(contentsOf: url))
        }
        return hashes
    }

    static func run(root: URL) async throws {
        let request = UUID(uuidString: "11111111-1111-4111-8111-000000000004")!
        let basic = try Fixture(root: root.appendingPathComponent("basic"))
        let firstInputs = try basic.inputs()
        let engine = try basic.engine()
        let first = try await engine.submit(requestID: request, items: firstInputs)
        try expect(first.importedCount == 2 && first.duplicateCount == 0, "Batch import failed")
        try checkComplete(basic, count: 2)
        try expect(try engine.provenance(documentID: firstInputs[0].documentID)?.originalSHA256 == firstInputs[0].sha256,
                   "Provenance was not retained")
        let beforeReplay = try treeHashes(basic.root), beforeCounts = try basic.counters()
        let repeatResult = try await engine.submit(requestID: request, items: basic.inputs(variant: "regenerated-ids"))
        try expect(repeatResult.replayed && repeatResult.documentIDs == first.documentIDs, "Same request did not reuse its original result")
        // Incoming fixture construction is outside the engine. Snapshot after it
        // to check that the engine performs no writes for a completed replay.
        let replayInputs = try basic.inputs(variant: "another-retry")
        let replayTree = try treeHashes(basic.root)
        _ = try await engine.submit(requestID: request, items: replayInputs)
        try expect(try treeHashes(basic.root) == replayTree, "Completed request replay wrote files")
        let conflictInputs = try basic.inputs(["different request body", "second fixture"], variant: "conflict")
        let conflictTree = try treeHashes(basic.root)
        try await rejected("Same request accepted different content") { _ = try await engine.submit(requestID: request, items: conflictInputs) }
        try expect(try treeHashes(basic.root) == conflictTree, "Conflicting request changed files")
        try expect(try basic.counters().commits == beforeCounts.commits && basic.counters().indexes == beforeCounts.indexes,
                   "Completed/conflicting request repeated side effects")
        try expect(!beforeReplay.isEmpty, "Missing fixture snapshot")
        let libraryHash = Fixture.sha(try Data(contentsOf: basic.libraryURL))
        let duplicates = try await engine.submit(requestID: UUID(), items: basic.inputs(variant: "same-sha"))
        try expect(duplicates.importedCount == 0 && duplicates.duplicateCount == 2, "Same SHA created duplicate documents")
        try expect(Fixture.sha(try Data(contentsOf: basic.libraryURL)) == libraryHash, "Same SHA changed the existing library")
        try checkComplete(basic, count: 2)

        let batchDuplicate = try Fixture(root: root.appendingPathComponent("batch-duplicate"))
        let batch = try await batchDuplicate.engine().submit(requestID: UUID(), items: batchDuplicate.inputs(["same bytes", "same bytes"]))
        try expect(batch.importedCount == 1 && batch.duplicateCount == 1 && batch.documentIDs.count == 1, "Within-batch SHA deduplication failed")
        try checkComplete(batchDuplicate, count: 1)

        let failed = try Fixture(root: root.appendingPathComponent("atomic-save-failure"))
        let failedInputs = try failed.inputs(), failedRequest = UUID()
        let failedEngine = try failed.engine()
        failed.failCommit = true
        try await rejected("JSON save failure was accepted") { _ = try await failedEngine.submit(requestID: failedRequest, items: failedInputs) }
        try expect(try failed.library().managedDocuments.isEmpty && failed.managedFiles().isEmpty, "JSON save failure left orphan documents/attachments")
        failed.failCommit = false
        let resumed = await failedEngine.recoverPending()
        try expect(resumed.first?.outcome?.importedCount == 2, "Failed JSON save could not recover")
        try checkComplete(failed, count: 2)

        let fileFailure = try Fixture(root: root.appendingPathComponent("attachment-failure"))
        let fileInputs = try fileFailure.inputs(), fileRequest = UUID()
        let brokenFileEngine = try fileFailure.engine(fault: { point in
            if point == .beforeAttachmentCommit(1) { throw Failure(description: "Injected second attachment failure") }
        })
        try await rejected("Attachment failure was accepted") { _ = try await brokenFileEngine.submit(requestID: fileRequest, items: fileInputs) }
        try expect(try fileFailure.library().managedDocuments.isEmpty && fileFailure.managedFiles().isEmpty, "Attachment failure compensation left orphan files")
        let fileRecovery = await (try fileFailure.engine()).recoverPending()
        try expect(fileRecovery.first?.outcome?.importedCount == 2, "Attachment failure could not recover")
        try checkComplete(fileFailure, count: 2)

        let cancelled = try Fixture(root: root.appendingPathComponent("cancelled"))
        let cancelRequest = UUID(), cancelInputs = try cancelled.inputs()
        var cancelEngine: ResearchImportJournal!
        cancelEngine = try cancelled.engine(progress: { stage, done, _ in
            if stage == .attachments && done == 1 { try? cancelEngine.cancel(requestID: cancelRequest) }
        })
        try await rejected("Cancellation was ignored") { _ = try await cancelEngine.submit(requestID: cancelRequest, items: cancelInputs) }
        try expect(try cancelled.library().managedDocuments.isEmpty && cancelled.managedFiles().isEmpty, "Cancellation left records or attachments")
        try expect(try cancelEngine.job(requestID: cancelRequest)?.stage == .cancelled, "Cancellation was not durable")
        try expect(await cancelEngine.recoverPending().isEmpty, "Cancelled request replayed")
        for input in cancelInputs { try expect(Fixture.sha(try Data(contentsOf: input.sourceURL)) == input.sha256, "Cancellation changed an original input") }

        let indexFailure = try Fixture(root: root.appendingPathComponent("index-failure"))
        indexFailure.failIndex = true
        let indexEngine = try indexFailure.engine(), indexRequest = UUID(), indexInputs = try indexFailure.inputs()
        try await rejected("Index failure was accepted") { _ = try await indexEngine.submit(requestID: indexRequest, items: indexInputs) }
        try expect(try indexFailure.library().managedDocuments.count == 2 && indexFailure.managedFiles().count == 2, "Index failure deleted committed documents")
        indexFailure.failIndex = false
        let indexRecovery = await indexEngine.recoverPending()
        try expect(indexRecovery.first?.outcome != nil, "Index recovery failed")
        try expect(try indexFailure.counters().commits == 1, "Index recovery committed duplicate records")
        try checkComplete(indexFailure, count: 2)

        let durableFailure = try Fixture(root: root.appendingPathComponent("uncertain-save"))
        durableFailure.failAfterDurableCommit = true
        let uncertainEngine = try durableFailure.engine()
        try await rejected("Post-save injected failure was ignored") {
            _ = try await uncertainEngine.submit(requestID: UUID(), items: durableFailure.inputs())
        }
        try expect(try durableFailure.library().managedDocuments.count == 2 && durableFailure.managedFiles().count == 2, "Uncertain durable save removed referenced attachments")
        durableFailure.failAfterDurableCommit = false
        _ = await uncertainEngine.recoverPending()
        try expect(try durableFailure.counters().commits == 1, "Uncertain save recovery replayed database commit")
        try checkComplete(durableFailure, count: 2)

        for crashPoint in ["after-staging", "after-journal", "after-attachment", "after-database", "after-index"] {
            let fixture = try Fixture(root: root.appendingPathComponent("crash-" + crashPoint))
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--crash-worker", crashPoint]
            child.environment = ProcessInfo.processInfo.environment.merging(["GQ_IMPORT_WORKER_ROOT": fixture.root.path]) { _, new in new }
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); child.waitUntilExit()
            try expect(child.terminationStatus == 77, "Crash worker did not stop at its requested boundary")
            let recoveryEngine = try fixture.engine()
            let recovered = await recoveryEngine.recoverPending()
            try expect(recovered.count == 1 && recovered[0].outcome?.importedCount == 2, "Process crash recovery failed at " + crashPoint)
            try checkComplete(fixture, count: 2)
            let completeTree = try treeHashes(fixture.root), counts = try fixture.counters()
            try expect(await recoveryEngine.recoverPending().isEmpty, "Completed job replayed during recovery")
            try expect(try treeHashes(fixture.root) == completeTree, "Completed recovery changed files")
            try expect(try fixture.counters().commits == counts.commits && fixture.counters().indexes == counts.indexes, "Completed job repeated effects")
            try expect(counts.commits == 1, "Crash recovery duplicated an atomic JSON commit")
        }
        print("PASS Import: atomic JSON adapter; multi-file SHA; request/conflict/same-SHA idempotency; cancellation; attachment/JSON compensation; durable-save/index recovery; 5 real process interruptions; no completed replay; business/game sentinel retained")
    }

    static func crashWorker(_ point: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["GQ_IMPORT_WORKER_ROOT"] else { throw Failure(description: "Missing worker fixture root") }
        let fixture = try Fixture(root: URL(fileURLWithPath: path), initialize: false)
        let target: ResearchImportJournal.FaultPoint
        switch point {
        case "after-staging": target = .afterStaging
        case "after-journal": target = .afterCommitJournal
        case "after-attachment": target = .afterAttachmentCommit(0)
        case "after-database": target = .afterDatabaseCommit
        case "after-index": target = .afterIndex
        default: throw Failure(description: "Unknown fixture interruption")
        }
        let engine = try fixture.engine(fault: { if $0 == target { _exit(77) } })
        _ = try await engine.submit(requestID: UUID(uuidString: "11111111-1111-4111-8111-000000000004")!, items: fixture.inputs())
        throw Failure(description: "Crash worker completed unexpectedly")
    }

    static func main() async {
        do {
            if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--crash-worker" {
                try await crashWorker(CommandLine.arguments[2]); return
            }
            guard let path = ProcessInfo.processInfo.environment["GQ_IMPORT_TEST_ROOT"] else { throw Failure(description: "Use scripts/test_import.sh") }
            let root = URL(fileURLWithPath: path, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await run(root: root)
        } catch {
            fputs("FAIL Import: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
