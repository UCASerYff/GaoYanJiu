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
        var version: String? = nil
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
        var indexGate: (() async throws -> Void)? = nil
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
                                     destinationRelativePath: record.relativePath, version: record.version)
                    }
                }, commitRecords: { items in
                    if self.failCommit { throw Failure(description: "Injected atomic JSON save failure") }
                    var library = try self.library()
                    for item in items {
                        let record = try JSONDecoder().decode(Record.self, from: item.recordData)
                        try expect(record.id == item.documentID, "Opaque record payload changed")
                        if item.effectiveOperation == .update {
                            guard let offset = library.managedDocuments.firstIndex(where: { $0.id == record.id }),
                                  let expected = item.expectedOriginal else { throw Failure(description: "Missing update CAS") }
                            let old = library.managedDocuments[offset]
                            try expect(old.scopeID == expected.scopeID && old.sha256 == expected.sha256 &&
                                       old.relativePath == expected.destinationRelativePath &&
                                       (expected.version == nil || old.version == expected.version), "Atomic adapter CAS failed")
                            library.managedDocuments[offset] = record
                        } else {
                            try expect(!library.managedDocuments.contains(where: { $0.id == record.id }), "Duplicate record commit")
                            library.managedDocuments.append(record)
                        }
                    }
                    try self.save(library)
                    var counts = try self.counters(); counts.commits += 1; try self.saveCounters(counts)
                    if self.failAfterDurableCommit { throw Failure(description: "Injected failure after durable JSON save") }
                }, indexDocuments: { ids in
                    if self.failIndex { throw Failure(description: "Injected index failure") }
                    try await self.indexGate?()
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

        func seedVersioned() async throws -> Record {
            var input = try inputs(["original version"], variant: "seed")[0]
            var record = try JSONDecoder().decode(Record.self, from: input.recordData)
            record.version = "v1"
            input.recordVersion = record.version
            input.recordData = try JSONEncoder().encode(record)
            _ = try await engine().submit(requestID: UUID(), items: [input])
            return try library().managedDocuments[0]
        }

        func updateInput(from original: Record, variant: String = "v2") throws -> ResearchImportJournal.Input {
            var input = try inputs(["edited content " + variant], variant: variant)[0]
            var record = try JSONDecoder().decode(Record.self, from: input.recordData)
            record.id = original.id
            record.version = variant
            input.id = "edited-item"
            input.documentID = original.id
            input.recordData = try JSONEncoder().encode(record)
            input.operation = .update
            input.expectedOriginal = Self.state(original)
            input.recordVersion = variant
            input.originalRecordData = try JSONEncoder().encode(original)
            input.provenance.documentID = original.id
            input.provenance.originalSHA256 = original.sha256
            input.revision = .init(documentID: original.id, originalDocumentID: original.id,
                                   originalSHA256: original.sha256, derivedSHA256: input.sha256, kind: "editedVersion")
            return input
        }

        static func state(_ record: Record) -> ResearchImportJournal.RecordState {
            .init(documentID: record.id, scopeID: record.scopeID, sha256: record.sha256,
                  destinationRelativePath: record.relativePath, version: record.version)
        }
    }

    static func expect(_ condition: Bool, _ description: String) throws {
        if !condition { throw Failure(description: description) }
    }
    static func rejected(_ description: String, _ body: () async throws -> Void) async throws {
        var failed = false
        do { try await body() } catch { failed = true }
        try expect(failed, description)
    }
    static func checkComplete(_ fixture: Fixture, count: Int, retainedOriginals: Int = 0) throws {
        let library = try fixture.library()
        try expect(library.managedDocuments.count == count, "Wrong durable record count")
        try expect(Set(library.managedDocuments.map(\.id)).count == count, "Duplicate durable IDs")
        try expect(library.originalBusinessAndGameState == Library().originalBusinessAndGameState, "Unrelated business/game data changed")
        try expect(library.managedDocuments.allSatisfy { $0.indexedText != nil }, "Index and records disagree")
        try expect(try fixture.managedFiles().count == count + retainedOriginals, "Untracked attachment files")
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
        try await runUpdates(root: root.appendingPathComponent("updates"))
        print("PASS Import: insert/update/revision CAS; request/same-SHA idempotency; 10 update failure boundaries; cancellation/JSON/index compensation; legacy jobs; retained originals/history; 13 real process interruptions; no completed replay; business/game sentinel retained")
    }

    static func runUpdates(root: URL) async throws {
        let fixture = try Fixture(root: root.appendingPathComponent("roundtrip"))
        let original = try await fixture.seedVersioned()
        let originalBytes = try Data(contentsOf: fixture.attachments.appendingPathComponent(original.relativePath))
        let engine = try fixture.engine(), request = UUID()
        let input = try fixture.updateInput(from: original)
        let result = try await engine.submit(requestID: request, items: [input])
        try expect(result.documentIDs == [original.id] && result.importedCount == 1, "Same-ID update did not commit")
        try checkComplete(fixture, count: 1, retainedOriginals: 1)
        try expect(try fixture.library().managedDocuments[0].version == "v2", "Update lost replayable result version")
        try expect(try Data(contentsOf: fixture.attachments.appendingPathComponent(original.relativePath)) == originalBytes, "Update changed original attachment")
        try expect(try engine.revision(documentID: original.id)?.originalSHA256 == original.sha256, "Update revision relationship missing")
        let history = try treeHashes(fixture.exchange.appendingPathComponent("Metadata/DocumentHistory"))
        try expect(history.keys.contains(where: { $0.hasSuffix("state.json") }) &&
                   history.values.contains(Fixture.sha(input.originalRecordData!)), "Original record/history snapshot missing")
        var retry = input
        retry.recordVersion = "regenerated-time"
        retry.destinationRelativePath = "summaryReports/fixture-folder/regenerated-name.txt"
        retry.provenance.importedAt = Date().addingTimeInterval(123)
        let before = try treeHashes(fixture.root), counts = try fixture.counters()
        let replay = try await engine.submit(requestID: request, items: [retry])
        try expect(replay.replayed && replay.documentIDs == [original.id], "Update replay did not reuse original result")
        try expect(try treeHashes(fixture.root) == before, "Completed update replay wrote files")
        try expect(try fixture.counters().commits == counts.commits && fixture.counters().indexes == counts.indexes, "Update replay repeated side effects")
        var conflict = input
        conflict.expectedOriginal?.version = "different-original-version"
        try await rejected("Update request accepted conflicting CAS") { _ = try await engine.submit(requestID: request, items: [conflict]) }
        try expect(try treeHashes(fixture.root) == before, "Conflicting update request changed files")
        let secondOriginal = try fixture.library().managedDocuments[0]
        _ = try await engine.submit(requestID: UUID(), items: [fixture.updateInput(from: secondOriginal, variant: "v3")])
        try checkComplete(fixture, count: 1, retainedOriginals: 2)
        try expect(try engine.revision(documentID: original.id)?.originalSHA256 == secondOriginal.sha256, "Second update overwrote revision history incorrectly")
        var derivative = try fixture.inputs(["derived attachment"], variant: "derivative")[0]
        let source = try fixture.library().managedDocuments[0]
        derivative.operation = .revision
        derivative.expectedOriginal = Fixture.state(source)
        derivative.provenance.originalSHA256 = source.sha256
        derivative.revision = .init(documentID: derivative.documentID, originalDocumentID: source.id,
                                     originalSHA256: source.sha256, derivedSHA256: derivative.sha256, kind: "derivedAttachment")
        _ = try await engine.submit(requestID: UUID(), items: [derivative])
        try checkComplete(fixture, count: 2, retainedOriginals: 2)
        try expect(try fixture.library().managedDocuments.first(where: { $0.id == source.id })?.sha256 == source.sha256,
                   "Revision changed its source record")
        var sameBytes = try fixture.inputs(["edited content v3"], variant: "same-bytes-revision")[0]
        sameBytes.operation = .revision
        sameBytes.expectedOriginal = Fixture.state(source)
        sameBytes.provenance.originalSHA256 = source.sha256
        sameBytes.revision = .init(documentID: sameBytes.documentID, originalDocumentID: source.id,
                                    originalSHA256: source.sha256, derivedSHA256: sameBytes.sha256, kind: "derivedAttachment")
        let explicitCopy = try await engine.submit(requestID: UUID(), items: [sameBytes])
        try expect(explicitCopy.importedCount == 1 && explicitCopy.duplicateCount == 0,
                   "Explicit new attachment with identical bytes was silently deduplicated")
        try checkComplete(fixture, count: 3, retainedOriginals: 2)

        let rejectedFixture = try Fixture(root: root.appendingPathComponent("cas-rejections"))
        let old = try await rejectedFixture.seedVersioned()
        let valid = try rejectedFixture.updateInput(from: old)
        let rejectingEngine = try rejectedFixture.engine()
        let oldLibrary = try Data(contentsOf: rejectedFixture.libraryURL)
        var legacy = valid; legacy.operation = nil; legacy.expectedOriginal = nil
        do {
            _ = try await rejectingEngine.submit(requestID: UUID(), items: [legacy])
            throw Failure(description: "Legacy insert accepted a different version at the same ID")
        } catch let error as ResearchImportJournal.JournalError {
            try expect(error == .recordConflict, "Legacy same-ID mismatch changed error semantics")
        }
        for field in ["sha", "scope", "path", "version", "missingCAS", "samePath"] {
            var invalid = valid
            switch field {
            case "sha":
                invalid.expectedOriginal?.sha256 = String(repeating: "a", count: 64)
                invalid.provenance.originalSHA256 = String(repeating: "a", count: 64)
                invalid.revision?.originalSHA256 = String(repeating: "a", count: 64)
            case "scope": invalid.expectedOriginal?.scopeID = "another-folder"
            case "path": invalid.expectedOriginal?.destinationRelativePath = "summaryReports/fixture-folder/another.txt"
            case "version": invalid.expectedOriginal?.version = "stale-v0"
            case "missingCAS": invalid.expectedOriginal = nil
            default: invalid.destinationRelativePath = old.relativePath
            }
            try await rejected("Update accepted stale/missing " + field) { _ = try await rejectingEngine.submit(requestID: UUID(), items: [invalid]) }
            try expect(try Data(contentsOf: rejectedFixture.libraryURL) == oldLibrary, "Rejected CAS modified the library")
            try expect(try rejectedFixture.managedFiles().count == 1, "Rejected CAS changed original files")
        }

        let failures: [(String, ResearchImportJournal.FaultPoint)] = [
            ("staging", .afterStaging), ("validated", .afterValidation), ("journal", .afterCommitJournal),
            ("before-file", .beforeAttachmentCommit(0)), ("after-file", .afterAttachmentCommit(0)),
            ("before-db", .beforeDatabaseCommit), ("after-db", .afterDatabaseCommit),
            ("before-index", .beforeIndex), ("after-index", .afterIndex), ("completion", .beforeCompleted)
        ]
        for (name, boundary) in failures {
            let failed = try Fixture(root: root.appendingPathComponent("failure-" + name))
            let old = try await failed.seedVersioned()
            let update = try failed.updateInput(from: old), id = UUID()
            let faulting = try failed.engine(fault: { if $0 == boundary { throw Failure(description: "Injected update boundary") } })
            try await rejected("Update failure boundary was ignored: " + name) { _ = try await faulting.submit(requestID: id, items: [update]) }
            try expect(try Data(contentsOf: failed.attachments.appendingPathComponent(old.relativePath)) == Data("original version".utf8), "Failure removed original attachment: " + name)
            let recovered = await (try failed.engine()).recoverPending()
            try expect(recovered.count == 1 && recovered[0].outcome?.documentIDs == [old.id], "Update failure recovery failed: " + name)
            try expect(try failed.counters().commits == 2, "Recovery duplicated/skipped update JSON commit: " + name)
            try checkComplete(failed, count: 1, retainedOriginals: 1)
        }
        for uncertain in [false, true] {
            let failed = try Fixture(root: root.appendingPathComponent(uncertain ? "uncertain-update-save" : "failed-update-save"))
            let old = try await failed.seedVersioned(), update = try failed.updateInput(from: old)
            failed.failCommit = !uncertain; failed.failAfterDurableCommit = uncertain
            try await rejected("Injected update save failure was ignored") { _ = try await failed.engine().submit(requestID: UUID(), items: [update]) }
            try expect(try failed.managedFiles().count == (uncertain ? 2 : 1), "Update save failure compensation was wrong")
            failed.failCommit = false; failed.failAfterDurableCommit = false
            let recovered = await (try failed.engine()).recoverPending()
            try expect(recovered.first?.outcome != nil, "Update atomic save recovery failed")
            try expect(try failed.counters().commits == 2, "Uncertain update commit replayed")
            try checkComplete(failed, count: 1, retainedOriginals: 1)
        }
        let cancelled = try Fixture(root: root.appendingPathComponent("cancelled-update"))
        let cancelOld = try await cancelled.seedVersioned(), cancelUpdate = try cancelled.updateInput(from: cancelOld), cancelID = UUID()
        var cancelEngine: ResearchImportJournal!
        cancelEngine = try cancelled.engine(progress: { stage, done, _ in
            if stage == .attachments && done == 1 { try? cancelEngine.cancel(requestID: cancelID) }
        })
        try await rejected("Update cancellation ignored") { _ = try await cancelEngine.submit(requestID: cancelID, items: [cancelUpdate]) }
        try expect(try cancelled.library().managedDocuments[0] == cancelOld && cancelled.managedFiles().count == 1, "Cancellation changed original version")
        try expect(await cancelEngine.recoverPending().isEmpty, "Cancelled update was replayed")

        let raced = try Fixture(root: root.appendingPathComponent("concurrent-version"))
        let raceOld = try await raced.seedVersioned(), raceUpdate = try raced.updateInput(from: raceOld)
        let raceEngine = try raced.engine(fault: { point in
            if point == .beforeDatabaseCommit {
                var value = try raced.library(); value.managedDocuments[0].version = "concurrently-edited"; try raced.save(value)
            }
        })
        try await rejected("Update overwrote concurrently changed record version") { _ = try await raceEngine.submit(requestID: UUID(), items: [raceUpdate]) }
        try expect(try raced.library().managedDocuments[0].version == "concurrently-edited", "Concurrent version CAS failed")
        let blocked = await (try raced.engine()).recoverPending()
        try expect(blocked.first?.errorCode == "recordConflict", "Stale update recovery bypassed CAS")
        try expect(try raced.managedFiles().count == 1, "CAS rejection left an unreferenced new attachment")
        try expect(try Data(contentsOf: raced.attachments.appendingPathComponent(raceOld.relativePath)) == Data("original version".utf8), "Concurrent update changed original bytes")

        let legacyFixture = try Fixture(root: root.appendingPathComponent("legacy-job"))
        let legacyID = UUID(), legacyInputs = try legacyFixture.inputs()
        let legacyEngine = try legacyFixture.engine(fault: { if $0 == .afterCommitJournal { throw ResearchImportJournal.SimulatedCrash() } })
        try await rejected("Legacy fixture did not stop") { _ = try await legacyEngine.submit(requestID: legacyID, items: legacyInputs) }
        let jobURL = legacyFixture.exchange.appendingPathComponent("Metadata/ImportJobs/" + legacyID.uuidString.lowercased() + ".json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: jobURL)) as! [String: Any]
        var rows = object["items"] as! [[String: Any]]
        for index in rows.indices {
            for key in ["operation", "expectedOriginal", "recordVersion", "originalRecordData", "previousProvenance", "previousRevision"] { rows[index].removeValue(forKey: key) }
        }
        object["items"] = rows
        try JSONSerialization.data(withJSONObject: object).write(to: jobURL, options: .atomic)
        let legacyRecovered = await (try legacyFixture.engine()).recoverPending()
        try expect(legacyRecovered.first?.outcome?.importedCount == 2, "Pre-update journal was not backward compatible")
        try checkComplete(legacyFixture, count: 2)

        let legacyCommitted = try Fixture(root: root.appendingPathComponent("legacy-durable-job"))
        let legacyDurableID = UUID()
        let legacyDurableEngine = try legacyCommitted.engine(fault: {
            if $0 == .afterDatabaseCommit { throw ResearchImportJournal.SimulatedCrash() }
        })
        try await rejected("Legacy durable fixture did not stop") {
            _ = try await legacyDurableEngine.submit(requestID: legacyDurableID, items: legacyCommitted.inputs())
        }
        // The upgraded adapter may expose version tokens which were absent in
        // an older job. Its saved SHA/path/ID still identify committed inserts.
        var newlyVersioned = try legacyCommitted.library()
        for offset in newlyVersioned.managedDocuments.indices { newlyVersioned.managedDocuments[offset].version = "new-adapter-token" }
        try legacyCommitted.save(newlyVersioned)
        let legacyDurableRecovery = await (try legacyCommitted.engine()).recoverPending()
        try expect(legacyDurableRecovery.first?.outcome?.importedCount == 2, "Legacy committed job rejected new adapter version tokens")
        try expect(try legacyCommitted.counters().commits == 1, "Legacy committed job replayed its insert")
        try checkComplete(legacyCommitted, count: 2)

        let locked = try Fixture(root: root.appendingPathComponent("locked-job"))
        var reachedIndex = false, releaseIndex = false
        locked.indexGate = {
            reachedIndex = true
            while !releaseIndex { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        let lockOwner = try locked.engine(), contender = try locked.engine()
        let lockedInputs = try locked.inputs()
        let ownerTask = Task { try await lockOwner.submit(requestID: UUID(), items: lockedInputs) }
        defer { releaseIndex = true }
        for _ in 0..<10_000 where !reachedIndex { try await Task.sleep(nanoseconds: 1_000_000) }
        try expect(reachedIndex, "Lock fixture did not reach its wait boundary")
        do {
            _ = try await contender.submit(requestID: UUID(), items: lockedInputs)
            throw Failure(description: "Concurrent engine acquired the transaction lock")
        } catch let error as ResearchImportJournal.JournalError {
            try expect(error == .busy, "Concurrent import did not report busy")
        }
        let contendedRecovery = await contender.recoverPending()
        try expect(contendedRecovery.first?.errorCode == "busy", "Recovery bypassed a held transaction lock")
        releaseIndex = true
        _ = try await ownerTask.value
        try checkComplete(locked, count: 2)
        try expect(await contender.recoverPending().isEmpty, "Completed locked transaction replayed")

        for crashPoint in ["after-staging", "after-validation", "after-journal", "after-attachment", "before-database", "after-database", "after-index", "before-completed"] {
            let crashed = try Fixture(root: root.appendingPathComponent("process-" + crashPoint))
            let old = try await crashed.seedVersioned()
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--update-crash-worker", crashPoint]
            child.environment = ProcessInfo.processInfo.environment.merging(["GQ_IMPORT_WORKER_ROOT": crashed.root.path]) { _, new in new }
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); child.waitUntilExit()
            try expect(child.terminationStatus == 77, "Update worker missed crash boundary: " + crashPoint)
            let recovering = try crashed.engine(), recovered = await recovering.recoverPending()
            try expect(recovered.count == 1 && recovered[0].outcome?.documentIDs == [old.id], "Real-process update recovery failed: " + crashPoint)
            try checkComplete(crashed, count: 1, retainedOriginals: 1)
            try expect(try crashed.counters().commits == 2, "Real-process recovery duplicated update commit")
            let before = try treeHashes(crashed.root)
            try expect(await recovering.recoverPending().isEmpty, "Completed update recovered twice")
            try expect(try treeHashes(crashed.root) == before, "Completed update recovery wrote files")
        }
    }

    static func crashWorker(_ point: String, update: Bool = false) async throws {
        guard let path = ProcessInfo.processInfo.environment["GQ_IMPORT_WORKER_ROOT"] else { throw Failure(description: "Missing worker fixture root") }
        let fixture = try Fixture(root: URL(fileURLWithPath: path), initialize: false)
        let target: ResearchImportJournal.FaultPoint
        switch point {
        case "after-staging": target = .afterStaging
        case "after-validation": target = .afterValidation
        case "after-journal": target = .afterCommitJournal
        case "after-attachment": target = .afterAttachmentCommit(0)
        case "before-database": target = .beforeDatabaseCommit
        case "after-database": target = .afterDatabaseCommit
        case "after-index": target = .afterIndex
        case "before-completed": target = .beforeCompleted
        default: throw Failure(description: "Unknown fixture interruption")
        }
        let engine = try fixture.engine(fault: { if $0 == target { _exit(77) } })
        let inputs = update ? [try fixture.updateInput(from: fixture.library().managedDocuments[0])] : try fixture.inputs()
        _ = try await engine.submit(requestID: UUID(uuidString: "11111111-1111-4111-8111-000000000004")!, items: inputs)
        throw Failure(description: "Crash worker completed unexpectedly")
    }

    static func main() async {
        do {
            if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--crash-worker" {
                try await crashWorker(CommandLine.arguments[2]); return
            }
            if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--update-crash-worker" {
                try await crashWorker(CommandLine.arguments[2], update: true); return
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
