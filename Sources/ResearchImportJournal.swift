import CryptoKit
import Darwin
import Foundation

/// Private sidecars; the research library remains the existing library.json.
struct DocumentProvenance: Codable, Equatable {
    struct Page: Codable, Equatable {
        var pageNumber: Int
        var text: String? = nil
        var bounds: [Double]? = nil
        var confidence: Double? = nil
        var status: String? = nil
    }
    var documentID: String
    var originalSHA256: String
    var sourceBundleID: String? = nil
    var sourceDeclaration: String? = nil
    var importedAt: Date = Date()
    var ocrEngine: String? = nil
    var ocrVersion: String? = nil
    var ocrLanguages: [String] = []
    var pages: [Page] = []
    var externalReferences: [String] = []
    var targetRecordID: String? = nil
}

struct AttachmentRevision: Codable, Equatable {
    var documentID: String
    var originalDocumentID: String
    var originalSHA256: String
    var derivedSHA256: String
    var kind: String
    var createdAt: Date = Date()
}

struct ProcessedRequest: Codable {
    enum State: String, Codable { case received, approved, executing, completed, cancelled, failed }
    var requestID: UUID
    var fingerprint: String
    var state: State
    var documentIDs: [String]
    var updatedAt: Date
}

struct ImportJob: Codable, Identifiable {
    enum Stage: String, Codable {
        case staging, validated, commitJournal, attachments, database, indexing
        case completed, cancelled, failed
    }
    var id: UUID { requestID }
    var format = 1
    var requestID: UUID
    var fingerprint: String
    var stage: Stage
    var items: [ResearchImportJournal.CommittedItem]
    var createdAt: Date
    var updatedAt: Date
    var validationCompleted = false
    var recordsCommitted = false
    var cancelRequested = false
    var errorCode: String? = nil
    var resumeStage: Stage? = nil
    var outcome: ResearchImportJournal.Outcome? = nil
}

/// A write-ahead file journal around the existing atomic JSON repository.
/// The adapter must expose durable records, atomically save the whole batch,
/// and roll back its in-memory changes if that save fails. Indexing must be
/// repeatable: a crash after indexing can require indexing the same IDs again.
@MainActor
final class ResearchImportJournal {
    enum Operation: String, Codable { case insert, update, revision }
    struct Input {
        var id: String
        var sourceURL: URL
        var documentID: String
        var scopeID: String
        var destinationRelativePath: String
        var sha256: String
        var byteCount: Int64
        var recordData: Data
        var provenance: DocumentProvenance
        var revision: AttachmentRevision? = nil
        var operation: Operation? = nil
        var expectedOriginal: RecordState? = nil
        var recordVersion: String? = nil
        var originalRecordData: Data? = nil
    }
    struct RecordState: Codable, Equatable {
        var documentID: String
        var scopeID: String
        var sha256: String
        var destinationRelativePath: String
        var version: String? = nil
    }
    struct CommittedItem: Codable {
        var id: String
        var documentID: String
        var scopeID: String
        var destinationRelativePath: String
        var sha256: String
        var byteCount: Int64
        /// Opaque adapter-owned JSON, never decoded as a second library here.
        var recordData: Data
        var provenance: DocumentProvenance
        var revision: AttachmentRevision?
        var duplicateOfDocumentID: String?
        var stagedRelativePath: String
        var destinationInitiallyAbsent = false
        // Optional fields keep journals written before explicit update support
        // decodable. A missing operation retains the original strict insert.
        var operation: Operation? = nil
        var expectedOriginal: RecordState? = nil
        var recordVersion: String? = nil
        var originalRecordData: Data? = nil
        var previousProvenance: DocumentProvenance? = nil
        var previousRevision: AttachmentRevision? = nil
        var effectiveOperation: Operation { operation ?? .insert }
        var newState: RecordState {
            RecordState(documentID: documentID, scopeID: scopeID, sha256: sha256,
                        destinationRelativePath: destinationRelativePath, version: recordVersion)
        }
    }
    struct Adapter {
        var currentRecords: @MainActor () throws -> [RecordState]
        var commitRecords: @MainActor ([CommittedItem]) throws -> Void
        var indexDocuments: @MainActor ([String]) async throws -> Void
    }
    struct Outcome: Codable, Equatable {
        var documentIDs: [String]
        var importedCount: Int
        var duplicateCount: Int
        var replayed: Bool
    }
    struct RecoveryResult {
        var requestID: UUID?
        var outcome: Outcome?
        var errorCode: String?
    }
    enum FaultPoint: Equatable {
        case afterStaging, afterValidation, afterCommitJournal
        case beforeAttachmentCommit(Int), afterAttachmentCommit(Int)
        case beforeDatabaseCommit, afterDatabaseCommit, beforeIndex, afterIndex, beforeCompleted
    }
    /// Tests use this to leave the on-disk journal exactly at an interruption.
    struct SimulatedCrash: Swift.Error {}
    enum JournalError: String, Swift.Error, LocalizedError {
        case busy, invalidPlan, invalidPath, corruptJournal, requestConflict
        case stagingIncomplete, digestMismatch, destinationConflict, recordConflict
        case revisionConflict, partialRecordCommit, cancelled, unsafeFile
        var errorDescription: String? {
            switch self {
            case .busy: return "另一个资料导入正在执行，请稍后重试。"
            case .requestConflict: return "请求编号已用于不同内容或目标，已停止导入。"
            case .cancelled: return "资料导入已取消，原文件未修改。"
            case .revisionConflict: return "原附件版本已变化，请重新复核后导入。"
            case .digestMismatch: return "文件内容或大小与摘要不符，已停止导入。"
            case .destinationConflict, .recordConflict: return "资料目标已变化，已保留原数据并停止导入。"
            case .stagingIncomplete: return "暂存文件不完整，请重新发送同一请求以继续。"
            case .partialRecordCommit: return "资料提交状态不一致，已保留文件和恢复记录。"
            case .corruptJournal: return "导入恢复记录无法读取，原资料保持不变。"
            default: return "导入资料校验失败，原资料保持不变。"
            }
        }
    }

    let exchangeRoot: URL
    let attachmentsRoot: URL
    var progress: ((ImportJob.Stage, Int, Int) -> Void)?
    private let adapter: Adapter
    private let failureInjector: ((FaultPoint) throws -> Void)?
    private let metadata: URL
    private let jobsRoot: URL
    private let stagingRoot: URL
    private var activeRequest: UUID?
    private var cancellationRequests: Set<UUID> = []
    private var lockFD: Int32 = -1
    private let encoder: JSONEncoder = {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value
    }()
    private let decoder = JSONDecoder()

    init(exchangeRoot: URL, attachmentsRoot: URL, adapter: Adapter,
         failureInjector: ((FaultPoint) throws -> Void)? = nil,
         progress: ((ImportJob.Stage, Int, Int) -> Void)? = nil) throws {
        self.exchangeRoot = exchangeRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.attachmentsRoot = attachmentsRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.adapter = adapter
        self.failureInjector = failureInjector
        self.progress = progress
        metadata = self.exchangeRoot.appendingPathComponent("Metadata", isDirectory: true)
        jobsRoot = metadata.appendingPathComponent("ImportJobs", isDirectory: true)
        stagingRoot = self.exchangeRoot.appendingPathComponent("ImportStaging", isDirectory: true)
        for root in [self.exchangeRoot, self.attachmentsRoot, metadata, jobsRoot, stagingRoot] {
            try Self.ensureDirectory(root)
        }
    }

    func job(requestID: UUID) throws -> ImportJob? {
        let url = jobURL(requestID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if FileManager.default.fileExists(atPath: requestURL(requestID).path) { throw JournalError.corruptJournal }
            return nil
        }
        let value: ImportJob = try decode(url)
        guard value.format == 1, value.requestID == requestID else { throw JournalError.corruptJournal }
        guard !value.items.isEmpty, value.items.count <= 256, Self.isDigest(value.fingerprint),
              Set(value.items.map(\.id)).count == value.items.count,
              Set(value.items.map(\.documentID)).count == value.items.count else { throw JournalError.corruptJournal }
        for (offset, item) in value.items.enumerated() {
            guard item.stagedRelativePath == "payload/\(offset).data", Self.isDigest(item.sha256),
                  item.byteCount >= 0, item.byteCount <= 2_147_483_648,
                  item.recordData.count <= 16 * 1_048_576,
                  (item.originalRecordData?.count ?? 0) <= 16 * 1_048_576 else { throw JournalError.corruptJournal }
            _ = try Self.safeRelative(item.destinationRelativePath)
            try Self.validateOperation(item.effectiveOperation, documentID: item.documentID, scopeID: item.scopeID,
                                       destination: item.destinationRelativePath, expected: item.expectedOriginal, revision: item.revision)
        }
        return value
    }

    func recentJobs(limit: Int = 20) throws -> [ImportJob] {
        let names = try FileManager.default.contentsOfDirectory(at: jobsRoot, includingPropertiesForKeys: nil)
        return try names.filter { $0.pathExtension == "json" }.map { url -> ImportJob in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let value = try job(requestID: id) else { throw JournalError.corruptJournal }
            return value
        }.sorted { $0.updatedAt > $1.updatedAt }.prefix(max(0, limit)).map { $0 }
    }

    func provenance(documentID: String) throws -> DocumentProvenance? {
        try optionalMetadata(documentID: documentID, directory: "DocumentProvenance")
    }

    func revision(documentID: String) throws -> AttachmentRevision? {
        try optionalMetadata(documentID: documentID, directory: "AttachmentRevisions")
    }

    func recordProvenanceDirectly(_ provenance: DocumentProvenance) throws {
        try writeMetadata(provenance, documentID: provenance.documentID, directory: "DocumentProvenance")
    }

    func recordRevisionDirectly(_ revision: AttachmentRevision) throws {
        try writeMetadata(revision, documentID: revision.documentID, directory: "AttachmentRevisions")
    }

    func cancel(requestID: UUID) throws {
        guard var value = try job(requestID: requestID), value.stage != .completed, value.stage != .cancelled else { return }
        cancellationRequests.insert(requestID)
        value.cancelRequested = true
        if !value.validationCompleted && activeRequest != requestID { value.stage = .cancelled }
        try persist(&value)
    }

    func submit(requestID: UUID, items: [Input]) async throws -> Outcome {
        let fingerprint = try makeFingerprint(items)
        if let value = try job(requestID: requestID) {
            guard value.fingerprint == fingerprint else { throw JournalError.requestConflict }
            if value.stage == .completed, var result = value.outcome {
                result.replayed = true
                return result
            }
            if value.stage == .cancelled { throw JournalError.cancelled }
        }
        try begin(requestID)
        defer { end() }
        var value: ImportJob
        if let existing = try job(requestID: requestID) {
            guard existing.fingerprint == fingerprint else { throw JournalError.requestConflict }
            value = existing
        } else {
            let now = Date()
            value = ImportJob(requestID: requestID, fingerprint: fingerprint, stage: .staging,
                              items: items.enumerated().map { offset, input in
                CommittedItem(id: input.id, documentID: input.documentID, scopeID: input.scopeID,
                              destinationRelativePath: input.destinationRelativePath, sha256: input.sha256.lowercased(),
                              byteCount: input.byteCount, recordData: input.recordData,
                              provenance: input.provenance, revision: input.revision,
                              duplicateOfDocumentID: nil, stagedRelativePath: "payload/\(offset).data",
                              operation: input.operation, expectedOriginal: input.expectedOriginal,
                              recordVersion: input.recordVersion, originalRecordData: input.originalRecordData)
            }, createdAt: now, updatedAt: now)
            try persist(&value)
        }
        do {
            try await stageMissingFiles(&value, inputs: items)
            return try await execute(&value)
        } catch is SimulatedCrash { throw SimulatedCrash() }
        catch {
            try await recordFailure(&value, error: error)
            throw error
        }
    }

    func recoverPending() async -> [RecoveryResult] {
        guard activeRequest == nil else { return [RecoveryResult(errorCode: JournalError.busy.rawValue)] }
        let jobs: [ImportJob]
        do { jobs = try recentJobs(limit: Int.max).reversed() }
        catch { return [RecoveryResult(errorCode: JournalError.corruptJournal.rawValue)] }
        var results: [RecoveryResult] = []
        for original in jobs where original.stage != .completed && original.stage != .cancelled {
            var value = original
            do { try begin(value.requestID) }
            catch {
                results.append(RecoveryResult(requestID: value.requestID, errorCode: errorCode(error)))
                continue
            }
            do {
                // The file lock covers both execution and compensation. Reload
                // after taking it: another process may have finished this job.
                guard let latest = try job(requestID: value.requestID) else { throw JournalError.corruptJournal }
                value = latest
                if value.stage == .completed || value.stage == .cancelled { end(); continue }
                let outcome = try await execute(&value)
                results.append(RecoveryResult(requestID: value.requestID, outcome: outcome))
            } catch is SimulatedCrash {
                results.append(RecoveryResult(requestID: value.requestID, errorCode: "interrupted"))
            } catch {
                do { try await recordFailure(&value, error: error) } catch { }
                results.append(RecoveryResult(requestID: value.requestID, errorCode: errorCode(error)))
            }
            end()
        }
        return results
    }

    private func execute(_ value: inout ImportJob) async throws -> Outcome {
        try await checkCancellation(value)
        let stageDirectory = stageURL(value.requestID)
        for item in value.items {
            try await Self.verifyFile(stageDirectory.appendingPathComponent(item.stagedRelativePath),
                                      sha256: item.sha256, byteCount: item.byteCount)
        }
        if !value.validationCompleted {
            try await validate(&value)
            value.validationCompleted = true
            try transition(&value, to: .validated)
            try failureInjector?(.afterValidation)
            try await checkCancellation(value)
            try transition(&value, to: .commitJournal)
            try failureInjector?(.afterCommitJournal)
        }

        let newItems = value.items.filter { $0.duplicateOfDocumentID == nil }
        let existing = try states()
        let committed = try matchingCommitted(newItems, records: existing)
        if committed != 0 && committed != newItems.count { throw JournalError.partialRecordCommit }
        if value.recordsCommitted && committed != newItems.count { throw JournalError.recordConflict }
        if committed == newItems.count && !newItems.isEmpty { value.recordsCommitted = true }
        try validateRelations(value.items, records: existing, recordsCommitted: value.recordsCommitted)
        try validateDuplicates(value.items, records: existing)
        for item in newItems where item.effectiveOperation == .update { try archiveOriginalMetadata(item) }

        try transition(&value, to: .attachments)
        for (offset, item) in newItems.enumerated() {
            try await checkCancellation(value)
            try failureInjector?(.beforeAttachmentCommit(offset))
            let destination = try destinationURL(item.destinationRelativePath)
            if FileManager.default.fileExists(atPath: destination.path) {
                guard item.destinationInitiallyAbsent || value.recordsCommitted else { throw JournalError.destinationConflict }
                try await Self.verifyFile(destination, sha256: item.sha256, byteCount: item.byteCount)
            } else {
                let source = stageDirectory.appendingPathComponent(item.stagedRelativePath)
                let temporary = temporaryDestination(item, requestID: value.requestID)
                try await Task.detached(priority: .utility) {
                    try Self.ensureDirectory(destination.deletingLastPathComponent())
                    if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
                    try Self.copyVerified(source: source, destination: temporary, sha256: item.sha256, byteCount: item.byteCount)
                    do { try FileManager.default.moveItem(at: temporary, to: destination) }
                    catch { try? FileManager.default.removeItem(at: temporary); throw error }
                }.value
            }
            progress?(.attachments, offset + 1, newItems.count)
            try failureInjector?(.afterAttachmentCommit(offset))
        }
        try await checkCancellation(value)
        if !value.recordsCommitted {
            let current = try states()
            try validateRelations(value.items, records: current)
            try validateDuplicates(value.items, records: current)
            let already = try matchingCommitted(newItems, records: current)
            if already != 0 { throw JournalError.recordConflict }
            // A concurrent import cannot silently turn this plan into a second
            // record for identical content in the same target scope.
            for item in newItems where item.effectiveOperation == .insert && current.contains(where: {
                $0.scopeID == item.scopeID && $0.sha256.lowercased() == item.sha256 && $0.documentID != item.documentID
            }) { throw JournalError.recordConflict }
            try transition(&value, to: .database)
            try failureInjector?(.beforeDatabaseCommit)
            // Compare immediately before the synchronous atomic adapter call,
            // including any edits made while files were being staged/copied.
            let beforeCommit = try states()
            try validateRelations(value.items, records: beforeCommit)
            try validatePending(newItems, records: beforeCommit)
            if !newItems.isEmpty { try adapter.commitRecords(newItems) }
            guard try matchingCommitted(newItems, records: states()) == newItems.count else { throw JournalError.partialRecordCommit }
            value.recordsCommitted = true
            try persist(&value)
            try failureInjector?(.afterDatabaseCommit)
        }
        // Once durable records exist, attachments must never be compensated.
        // An indexing failure remains a recoverable job with those same IDs.
        try transition(&value, to: .indexing)
        try failureInjector?(.beforeIndex)
        if !newItems.isEmpty { try await adapter.indexDocuments(newItems.map(\.documentID)) }
        try failureInjector?(.afterIndex)
        for item in newItems {
            if item.effectiveOperation == .update {
                try writeUpdatedMetadata(item.provenance, previous: item.previousProvenance,
                                         documentID: item.documentID, directory: "DocumentProvenance")
            } else {
                try writeMetadata(item.provenance, documentID: item.documentID, directory: "DocumentProvenance")
            }
            if let revision = item.revision {
                if item.effectiveOperation == .update {
                    try writeUpdatedMetadata(revision, previous: item.previousRevision,
                                             documentID: item.documentID, directory: "AttachmentRevisions")
                } else {
                    try writeMetadata(revision, documentID: item.documentID, directory: "AttachmentRevisions")
                }
            }
        }
        let ids = value.items.map { $0.duplicateOfDocumentID ?? $0.documentID }
        var seen: Set<String> = []
        let outcome = Outcome(documentIDs: ids.filter { seen.insert($0).inserted }, importedCount: newItems.count,
                              duplicateCount: value.items.count - newItems.count, replayed: false)
        value.outcome = outcome
        try failureInjector?(.beforeCompleted)
        try transition(&value, to: .completed)
        try? FileManager.default.removeItem(at: stageDirectory)
        return outcome
    }

    private func stageMissingFiles(_ value: inout ImportJob, inputs: [Input]) async throws {
        let directory = stageURL(value.requestID)
        try Self.ensureDirectory(directory)
        let byID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0) })
        progress?(.staging, 0, value.items.count)
        for (offset, item) in value.items.enumerated() {
            try await checkCancellation(value)
            let destination = directory.appendingPathComponent(item.stagedRelativePath)
            if FileManager.default.fileExists(atPath: destination.path) {
                try await Self.verifyFile(destination, sha256: item.sha256, byteCount: item.byteCount)
            } else {
                guard let input = byID[item.id] else { throw JournalError.stagingIncomplete }
                try await Task.detached(priority: .utility) {
                    try Self.ensureDirectory(destination.deletingLastPathComponent())
                    let temporary = destination.appendingPathExtension("partial")
                    if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
                    try Self.copyVerified(source: input.sourceURL, destination: temporary,
                                          sha256: item.sha256, byteCount: item.byteCount)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }.value
            }
            progress?(.staging, offset + 1, value.items.count)
        }
        try failureInjector?(.afterStaging)
    }

    private func validate(_ value: inout ImportJob) async throws {
        let current = try states()
        try validateRelations(value.items, records: current)
        var digestTargets: [String: String] = [:]
        for state in current { digestTargets[state.scopeID + "\0" + state.sha256.lowercased()] = state.documentID }
        for offset in value.items.indices {
            var item = value.items[offset]
            if item.effectiveOperation == .update || item.effectiveOperation == .revision {
                if item.effectiveOperation == .update {
                    guard let expected = item.expectedOriginal,
                          let state = current.first(where: { $0.documentID == item.documentID }),
                          matchesState(state, expected: expected) else { throw JournalError.recordConflict }
                } else if current.contains(where: { $0.documentID == item.documentID }) {
                    throw JournalError.recordConflict
                }
                let destination = try destinationURL(item.destinationRelativePath)
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw JournalError.destinationConflict }
                item.destinationInitiallyAbsent = true
                if item.effectiveOperation == .update {
                    item.previousProvenance = try provenance(documentID: item.documentID)
                    item.previousRevision = try revision(documentID: item.documentID)
                }
                digestTargets[item.scopeID + "\0" + item.sha256] = item.documentID
                value.items[offset] = item
                continue
            }
            if let state = current.first(where: { $0.documentID == item.documentID }),
               !matches(item, state) { throw JournalError.recordConflict }
            let key = item.scopeID + "\0" + item.sha256
            if let duplicate = digestTargets[key] {
                item.duplicateOfDocumentID = duplicate
            } else {
                let destination = try destinationURL(item.destinationRelativePath)
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw JournalError.destinationConflict }
                item.destinationInitiallyAbsent = true
                digestTargets[key] = item.documentID
            }
            value.items[offset] = item
        }
        progress?(.validated, value.items.count, value.items.count)
    }

    private func states() throws -> [RecordState] {
        let result = try adapter.currentRecords()
        guard Set(result.map(\.documentID)).count == result.count else { throw JournalError.recordConflict }
        return result
    }

    private func validateRelations(_ items: [CommittedItem], records: [RecordState], recordsCommitted: Bool = false) throws {
        for item in items {
            guard item.provenance.documentID == item.documentID else { throw JournalError.invalidPlan }
            var original: RecordState?
            if let expected = item.expectedOriginal {
                if recordsCommitted {
                    // A committed update has replaced the same logical ID.
                    // The durable job preserves the old state; requiring the
                    // old SHA on the new record would prevent index recovery.
                    original = expected
                } else {
                    guard let current = records.first(where: { $0.documentID == expected.documentID }),
                          matchesState(current, expected: expected) else { throw JournalError.recordConflict }
                    original = current
                }
            }
            if let revision = item.revision {
                let source = original ?? records.first(where: { $0.documentID == revision.originalDocumentID })
                guard revision.documentID == item.documentID, revision.derivedSHA256.lowercased() == item.sha256,
                      let source, source.documentID == revision.originalDocumentID,
                      source.sha256.lowercased() == revision.originalSHA256.lowercased(),
                      item.provenance.originalSHA256.lowercased() == revision.originalSHA256.lowercased() else {
                    throw JournalError.revisionConflict
                }
            } else if item.provenance.originalSHA256.lowercased() != (original?.sha256.lowercased() ?? item.sha256) {
                throw JournalError.revisionConflict
            }
        }
    }

    private func validateDuplicates(_ items: [CommittedItem], records: [RecordState]) throws {
        let planned = Set(items.filter { $0.duplicateOfDocumentID == nil }.map(\.documentID))
        for item in items {
            guard let duplicate = item.duplicateOfDocumentID, !planned.contains(duplicate) else { continue }
            guard let state = records.first(where: { $0.documentID == duplicate }),
                  state.scopeID == item.scopeID, state.sha256.lowercased() == item.sha256 else { throw JournalError.recordConflict }
        }
    }

    private func matchingCommitted(_ items: [CommittedItem], records: [RecordState]) throws -> Int {
        var count = 0
        for item in items {
            if let state = records.first(where: { $0.documentID == item.documentID }) {
                if matches(item, state) { count += 1 }
                else if item.effectiveOperation == .update, let expected = item.expectedOriginal,
                        matchesState(state, expected: expected) { continue }
                else { throw JournalError.recordConflict }
            } else if item.effectiveOperation == .update {
                throw JournalError.recordConflict
            }
        }
        return count
    }

    private func matches(_ item: CommittedItem, _ state: RecordState) -> Bool {
        matchesState(state, expected: item.newState)
    }

    private func matchesState(_ actual: RecordState, expected: RecordState) -> Bool {
        actual.documentID == expected.documentID && actual.scopeID == expected.scopeID &&
        actual.sha256.lowercased() == expected.sha256.lowercased() &&
        actual.destinationRelativePath == expected.destinationRelativePath &&
        (expected.version == nil || actual.version == expected.version)
    }

    private func validatePending(_ items: [CommittedItem], records: [RecordState]) throws {
        for item in items {
            let current = records.first { $0.documentID == item.documentID }
            if item.effectiveOperation == .update {
                guard let current, let expected = item.expectedOriginal,
                      matchesState(current, expected: expected) else { throw JournalError.recordConflict }
            } else if current != nil { throw JournalError.recordConflict }
        }
    }

    private func checkCancellation(_ value: ImportJob) async throws {
        guard !value.recordsCommitted else { return }
        let persistedCancellation = try job(requestID: value.requestID)?.cancelRequested == true
        if Task.isCancelled || cancellationRequests.contains(value.requestID) ||
            persistedCancellation { throw JournalError.cancelled }
    }

    private func recordFailure(_ value: inout ImportJob, error: Swift.Error) async throws {
        let newItems = value.items.filter { $0.duplicateOfDocumentID == nil }
        let current = try states() // An unreadable library never permits compensation.
        let committed: Int
        do { committed = try matchingCommitted(newItems, records: current) }
        catch {
            // A changed target is not evidence of a successful update. Only
            // remove this job's verified new files which no durable record
            // references; retain originals, staging, and the failed journal.
            if !value.recordsCommitted && value.validationCompleted {
                try await compensateUnreferenced(newItems, records: current, requestID: value.requestID)
            }
            value.errorCode = errorCode(error)
            value.resumeStage = value.recordsCommitted ? .indexing : .commitJournal
            value.stage = .failed
            try persist(&value)
            return
        }
        if committed > 0 || value.recordsCommitted {
            value.recordsCommitted = true
        } else if value.validationCompleted {
            try await compensateUnreferenced(newItems, records: current, requestID: value.requestID)
        }
        value.resumeStage = value.recordsCommitted ? .indexing : (value.validationCompleted ? .commitJournal : .staging)
        value.errorCode = errorCode(error)
        let cancelled = error is CancellationError || (error as? JournalError) == .cancelled
        value.stage = cancelled && !value.recordsCommitted ? .cancelled : .failed
        try persist(&value)
    }

    private func compensateUnreferenced(_ items: [CommittedItem], records: [RecordState], requestID: UUID) async throws {
        for item in items where item.destinationInitiallyAbsent {
            if records.contains(where: { $0.destinationRelativePath == item.destinationRelativePath }) { continue }
            let destination = try destinationURL(item.destinationRelativePath)
            let temporary = temporaryDestination(item, requestID: requestID)
            try await Task.detached(priority: .utility) {
                if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try Self.verifyFileSync(destination, sha256: item.sha256, byteCount: item.byteCount)
                    try FileManager.default.removeItem(at: destination)
                }
            }.value
        }
    }

    private func makeFingerprint(_ items: [Input]) throws -> String {
        guard !items.isEmpty, items.count <= 256, Set(items.map(\.id)).count == items.count,
              Set(items.map(\.documentID)).count == items.count else { throw JournalError.invalidPlan }
        var total: Int64 = 0
        var rows: [[String: String]] = []
        var destinations: Set<String> = []
        for item in items {
            guard !item.id.isEmpty, !item.documentID.isEmpty, !item.scopeID.isEmpty,
                  Self.isDigest(item.sha256), Self.isDigest(item.provenance.originalSHA256),
                  item.byteCount >= 0, item.byteCount <= 2_147_483_648,
                  item.recordData.count <= 16 * 1_048_576,
                  (item.originalRecordData?.count ?? 0) <= 16 * 1_048_576,
                  destinations.insert(item.destinationRelativePath).inserted else { throw JournalError.invalidPlan }
            _ = try Self.safeRelative(item.destinationRelativePath)
            let operation = item.operation ?? .insert
            try Self.validateOperation(operation, documentID: item.documentID, scopeID: item.scopeID,
                                       destination: item.destinationRelativePath, expected: item.expectedOriginal, revision: item.revision)
            total += item.byteCount
            guard total <= 2_147_483_648 else { throw JournalError.invalidPlan }
            var row = ["id": item.id, "scope": item.scopeID, "sha256": item.sha256.lowercased(),
                         "bytes": String(item.byteCount), "sourceSHA256": item.provenance.originalSHA256.lowercased(),
                         "targetRecordID": item.provenance.targetRecordID ?? "",
                         "revisionSource": item.revision?.originalDocumentID ?? "",
                         "revisionSHA256": item.revision?.originalSHA256.lowercased() ?? "",
                         "revisionKind": item.revision?.kind ?? ""]
            // nil and explicit insert have identical semantics, retaining the
            // fingerprints of legacy jobs. New update/revision intent and CAS
            // are bound to the request; generated result times are not.
            if operation != .insert {
                row["operation"] = operation.rawValue
                if operation == .update { row["documentID"] = item.documentID }
                if var expected = item.expectedOriginal {
                    expected.sha256 = expected.sha256.lowercased()
                    row["expectedOriginal"] = String(data: try encoder.encode(expected), encoding: .utf8)!
                }
            }
            rows.append(row)
        }
        let data = try JSONSerialization.data(withJSONObject: rows.sorted { $0["id"]! < $1["id"]! }, options: [.sortedKeys])
        return Self.hash(data)
    }

    private func transition(_ value: inout ImportJob, to stage: ImportJob.Stage) throws {
        value.stage = stage
        value.errorCode = nil
        try persist(&value)
        progress?(stage, 0, value.items.count)
    }

    private func persist(_ value: inout ImportJob) throws {
        value.updatedAt = Date()
        if cancellationRequests.contains(value.requestID) { value.cancelRequested = true }
        try write(value, to: jobURL(value.requestID)) // Authoritative journal first.
        let state: ProcessedRequest.State
        switch value.stage {
        case .staging: state = .received
        case .validated: state = .approved
        case .completed: state = .completed
        case .cancelled: state = .cancelled
        case .failed: state = .failed
        default: state = .executing
        }
        let request = ProcessedRequest(requestID: value.requestID, fingerprint: value.fingerprint, state: state,
                                       documentIDs: value.outcome?.documentIDs ?? [], updatedAt: value.updatedAt)
        try write(request, to: requestURL(value.requestID))
    }

    private func begin(_ id: UUID) throws {
        guard activeRequest == nil else { throw JournalError.busy }
        let fd = open(metadata.appendingPathComponent("import.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw JournalError.unsafeFile }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw JournalError.busy }
        lockFD = fd
        activeRequest = id
    }

    private func end() {
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
        lockFD = -1
        activeRequest = nil
    }

    private func errorCode(_ error: Swift.Error) -> String {
        if let error = error as? JournalError { return error.rawValue }
        if error is CancellationError { return JournalError.cancelled.rawValue }
        return "operationFailed"
    }

    private func jobURL(_ id: UUID) -> URL { jobsRoot.appendingPathComponent(id.uuidString.lowercased() + ".json") }
    private func stageURL(_ id: UUID) -> URL { stagingRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    private func requestURL(_ id: UUID) -> URL {
        metadata.appendingPathComponent("ProcessedRequests", isDirectory: true).appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private func destinationURL(_ relative: String) throws -> URL {
        let components = try Self.safeRelative(relative)
        var destination = attachmentsRoot
        for component in components {
            destination.appendPathComponent(component)
            if FileManager.default.fileExists(atPath: destination.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw JournalError.invalidPath }
            }
        }
        return destination
    }

    private func temporaryDestination(_ item: CommittedItem, requestID: UUID) -> URL {
        let destination = attachmentsRoot.appendingPathComponent(item.destinationRelativePath)
        return destination.deletingLastPathComponent().appendingPathComponent(".import-" + requestID.uuidString.lowercased() + "-" + Self.hash(Data(item.documentID.utf8)))
    }

    private func optionalMetadata<T: Decodable>(documentID: String, directory: String) throws -> T? {
        let url = metadata.appendingPathComponent(directory).appendingPathComponent(Self.hash(Data(documentID.utf8)) + ".json")
        return FileManager.default.fileExists(atPath: url.path) ? try decode(url) : nil
    }

    private func writeMetadata<T: Codable>(_ value: T, documentID: String, directory: String) throws {
        let url = metadata.appendingPathComponent(directory).appendingPathComponent(Self.hash(Data(documentID.utf8)) + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            let previous: T = try decode(url)
            guard try encoder.encode(previous) == encoder.encode(value) else { throw JournalError.recordConflict }
            return
        }
        try write(value, to: url)
    }

    private func archiveOriginalMetadata(_ item: CommittedItem) throws {
        guard let original = item.expectedOriginal else { throw JournalError.invalidPlan }
        let directory = metadata.appendingPathComponent("DocumentHistory", isDirectory: true)
            .appendingPathComponent(Self.hash(Data(item.documentID.utf8)), isDirectory: true)
            .appendingPathComponent(Self.hash(try encoder.encode(original)), isDirectory: true)
        try writeFrozen(original, to: directory.appendingPathComponent("state.json"))
        if let value = item.previousProvenance { try writeFrozen(value, to: directory.appendingPathComponent("provenance.json")) }
        if let value = item.previousRevision { try writeFrozen(value, to: directory.appendingPathComponent("revision.json")) }
        if let value = item.originalRecordData { try writeFrozenData(value, to: directory.appendingPathComponent("original-record.data")) }
        // The original attachment deliberately stays at original's path. The
        // immutable history state and optional record snapshot retain its link.
    }

    private func writeFrozen<T: Encodable>(_ value: T, to url: URL) throws {
        try writeFrozenData(encoder.encode(value), to: url)
    }

    private func writeFrozenData(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  try Data(contentsOf: url) == data else { throw JournalError.recordConflict }
            return
        }
        try Self.ensureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func writeUpdatedMetadata<T: Codable>(_ value: T, previous: T?, documentID: String, directory: String) throws {
        let url = metadata.appendingPathComponent(directory).appendingPathComponent(Self.hash(Data(documentID.utf8)) + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            let current: T = try decode(url)
            let encoded = try encoder.encode(current)
            if encoded == (try encoder.encode(value)) { return } // Interrupted after this write.
            guard let previous, encoded == (try encoder.encode(previous)) else { throw JournalError.recordConflict }
        } else if previous != nil { throw JournalError.recordConflict }
        try write(value, to: url)
    }

    private func decode<T: Decodable>(_ url: URL) throws -> T {
        do {
            let metadata = try FileManager.default.attributesOfItem(atPath: url.path)
            guard metadata[.type] as? FileAttributeType == .typeRegular else { throw JournalError.corruptJournal }
            return try decoder.decode(T.self, from: Data(contentsOf: url))
        } catch { throw JournalError.corruptJournal }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try Self.ensureDirectory(url.deletingLastPathComponent())
        try encoder.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private nonisolated static func safeRelative(_ value: String) throws -> [String] {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0"),
              !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw JournalError.invalidPath }
        return parts
    }

    private nonisolated static func validateOperation(_ operation: Operation, documentID: String, scopeID: String,
                                                      destination: String, expected: RecordState?, revision: AttachmentRevision?) throws {
        if operation == .insert {
            guard expected == nil else { throw JournalError.invalidPlan }
            return
        }
        guard let expected, !expected.documentID.isEmpty, !expected.scopeID.isEmpty,
              isDigest(expected.sha256), let revision,
              revision.originalDocumentID == expected.documentID,
              revision.originalSHA256.lowercased() == expected.sha256.lowercased() else { throw JournalError.invalidPlan }
        _ = try safeRelative(expected.destinationRelativePath)
        if operation == .update {
            guard expected.documentID == documentID, expected.scopeID == scopeID,
                  expected.destinationRelativePath != destination else { throw JournalError.invalidPlan }
        } else {
            guard expected.documentID != documentID else { throw JournalError.invalidPlan }
        }
    }

    private nonisolated static func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw JournalError.invalidPath }
            return
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for part in url.pathComponents.dropFirst() {
            current.appendPathComponent(part, isDirectory: true)
            var currentIsDir: ObjCBool = false
            if fm.fileExists(atPath: current.path, isDirectory: &currentIsDir) {
                guard currentIsDir.boolValue else { throw JournalError.invalidPath }
            } else {
                try fm.createDirectory(at: current, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        }
    }

    private nonisolated static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    private nonisolated static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private nonisolated static func verifyFile(_ url: URL, sha256: String, byteCount: Int64) async throws {
        try await Task.detached(priority: .utility) { try verifyFileSync(url, sha256: sha256, byteCount: byteCount) }.value
    }

    private nonisolated static func verifyFileSync(_ url: URL, sha256: String, byteCount: Int64) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw JournalError.stagingIncomplete }
        let result = try readVerified(url, destination: nil, byteCount: byteCount)
        guard result.0 == sha256.lowercased(), result.1 == byteCount else { throw JournalError.digestMismatch }
    }

    private nonisolated static func copyVerified(source: URL, destination: URL, sha256: String, byteCount: Int64) throws {
        var produced = false
        do {
            let result = try readVerified(source, destination: destination, byteCount: byteCount)
            produced = true
            guard result.0 == sha256.lowercased(), result.1 == byteCount else { throw JournalError.digestMismatch }
        } catch {
            if produced { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }

    /// Fixed FD protects identity; before/after metadata plus SHA detects content
    /// changes. Output is exclusive and is published only after verification.
    private nonisolated static func readVerified(_ source: URL, destination: URL?, byteCount: Int64) throws -> (String, Int64) {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw JournalError.unsafeFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1, before.st_uid == getuid() else { throw JournalError.unsafeFile }
        guard Int64(before.st_size) == byteCount else { throw JournalError.digestMismatch }
        var writer: FileHandle?
        var succeeded = false
        if let destination {
            let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard output >= 0 else { throw JournalError.destinationConflict }
            writer = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        }
        defer {
            try? writer?.close()
            if !succeeded, writer != nil, let destination { try? FileManager.default.removeItem(at: destination) }
        }
        var checksum = SHA256(), bytes: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            checksum.update(data: data)
            bytes += Int64(data.count)
            guard bytes <= byteCount else { throw JournalError.digestMismatch }
            try writer?.write(contentsOf: data)
        }
        try writer?.synchronize()
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw JournalError.digestMismatch }
        succeeded = true
        return (checksum.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }
}
