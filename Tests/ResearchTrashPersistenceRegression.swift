import Foundation
import Darwin

#if !RESEARCH_WIDGET_STORE_REGRESSION
#error("Use scripts/test_widget_store.sh with isolated data, publication paths and in-memory defaults.")
#endif

/// Match the existing product integration preference seam. No real preference
/// domain is opened by this executable, including from production sources.
final class UserDefaults {
    static let standard = UserDefaults(domain: "widget-store.standard")
    static let didChangeNotification = Notification.Name("ResearchWidgetStoreDefaultsChanged")
    private static let lock = NSLock()
    private static var values: [String: [String: Any]] = [:]
    private let domain: String
    private init(domain: String) { self.domain = domain }
    convenience init?(suiteName: String?) {
        guard suiteName == "com.academic-achievement.manager.test.Research" else { return nil }
        self.init(domain: suiteName!)
    }
    func object(forKey key: String) -> Any? { Self.lock.lock(); defer { Self.lock.unlock() }; return Self.values[domain]?[key] }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    func set(_ value: Any?, forKey key: String) { Self.lock.lock(); defer { Self.lock.unlock() }; Self.values[domain, default: [:]][key] = value }
    func removeObject(forKey key: String) { set(nil, forKey: key) }
}

/// Test-only seam inserted at the unique production copyItem call in a private
/// source snapshot when an explicit copy-race case is requested. The catch and
/// all safety logic remain byte-for-byte production source.
@MainActor
enum ResearchTrashCopyFault {
    static var handler: ((URL, URL) throws -> Void)?
    static var calls = 0
    static func beforeCopy(source: URL, destination: URL) throws {
        guard let action = handler else { return }
        handler = nil; calls += 1
        try action(source, destination)
    }
}

@MainActor
@main
struct ResearchTrashPersistenceRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    enum Injected: Error { case beforeSave, afterSave, unreadableAfterSave }
    final class FaultingDiskRepository: LibraryRepository {
        let disk = DiskLibraryRepository()
        var failure: Injected?
        var afterSave: (() throws -> Void)?
        var libraryURL: URL { disk.libraryURL }
        var applicationSupportURL: URL { disk.applicationSupportURL }
        var currentVersion: Int { disk.currentVersion }
        var migrationThresholds: [Int] { disk.migrationThresholds }
        func loadLibrary(migratingWith migrate: (inout PersistedLibrary, Int) -> Void) -> LibraryLoadResult { disk.loadLibrary(migratingWith: migrate) }
        func saveLibrary(_ library: PersistedLibrary) throws {
            let injected = failure; failure = nil
            if injected == .beforeSave { throw Injected.beforeSave }
            if injected == .afterSave || injected == .unreadableAfterSave {
                // Write the actual library, then throw without advancing the
                // disk repository's old compare-and-save baseline. This models
                // a rename which succeeded before parent-directory fsync failed.
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                try GaoActionFileAccess.writePrivateData(encoder.encode(library), to: libraryURL)
                if injected == .unreadableAfterSave { try Data("synthetic interrupted unreadable library".utf8).write(to: libraryURL) }
                throw injected!
            }
            try disk.saveLibrary(library)
            let action = afterSave; afterSave = nil; try action?()
        }
    }
    enum Kind: String, CaseIterable { case work, certificate, document, folder, workAttachment, certificateAttachment, noPayload }
    static var assertions = 0
    static let bytes = Data("Public synthetic attachment bytes\n".utf8)
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(description: message) }; assertions += 1
    }
    static func durable(_ repo: FaultingDiskRepository) throws -> PersistedLibrary {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PersistedLibrary.self, from: GaoActionFileAccess.readPrivateData(at: repo.libraryURL))
    }
    static func writeExternal(_ library: PersistedLibrary, _ repo: FaultingDiskRepository) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try GaoActionFileAccess.writePrivateData(encoder.encode(library), to: repo.libraryURL)
    }
    @MainActor
    struct Fixture {
        let kind: Kind
        let repo: FaultingDiskRepository
        let store: PaperStore
        let active: URL?
        let recordID: String
        func delete() {
            switch kind {
            case .work, .noPayload: store.moveWorkToTrash(store.existingWorks[0])
            case .certificate: store.moveCertificateToTrash(store.certificates[0])
            case .document: store.moveDocumentToTrash(store.managedDocuments[0])
            case .folder: store.moveDocumentFolderToTrash(id: store.documentFolders[0].id)
            case .workAttachment: store.moveWorkAttachmentToTrash(store.existingWorks[0].attachments[0], workID: store.existingWorks[0].id)
            case .certificateAttachment: store.moveCertificateAttachmentToTrash(store.certificates[0].attachments[0], recordID: store.certificates[0].id)
            }
        }
        func activeRecordExists(_ library: PersistedLibrary) -> Bool {
            switch kind {
            case .work, .noPayload: return library.existingWorks.contains { $0.id == recordID }
            case .certificate: return library.certificates.contains { $0.id == recordID }
            case .document: return library.managedDocuments.contains { $0.id == recordID }
            case .folder: return library.documentFolders.contains { $0.id == recordID }
            case .workAttachment: return library.existingWorks.contains { $0.attachments.contains { $0.id == recordID } }
            case .certificateAttachment: return library.certificates.contains { $0.attachments.contains { $0.id == recordID } }
            }
        }
        func memoryActive() -> Bool {
            activeRecordExists(PersistedLibrary(existingWorks: store.existingWorks, certificates: store.certificates,
                                               documentFolders: store.documentFolders, managedDocuments: store.managedDocuments))
        }
        func payload(_ item: TrashItem) -> URL {
            let root = store.trashStore.trashDirectory(item.id).appendingPathComponent("payload")
            return [.work, .certificate, .folder].contains(kind) ? root.appendingPathComponent("public.txt") : root
        }
        func orphanSafetyPayload() throws -> URL {
            let directories = try FileManager.default.contentsOfDirectory(at: TrashStore.storageURL, includingPropertiesForKeys: nil)
            guard let root = directories.first else { throw Failure(description: "Missing retained safety copy") }
            let payload = root.appendingPathComponent("payload")
            return [.work, .certificate, .folder].contains(kind) ? payload.appendingPathComponent("public.txt") : payload
        }
    }
    static func fixture(_ kind: Kind) throws -> Fixture {
        let repo = FaultingDiskRepository(), now = Date()
        try repo.disk.initializeNewLibraryAfterUserConfirmation()
        let attachment = WorkAttachment(id: "synthetic-attachment", originalName: "public.txt", storedName: "public.txt", kind: "text", addedAt: now)
        let work = ExistingWork(id: "synthetic-work", title: "Public synthetic trash persistence", type: .journalArticle,
            venue: "Fixture", authors: "Fixture", completedAt: now, identifier: "", url: "", notes: "",
            attachments: kind == .noPayload ? [] : [attachment], createdAt: now, updatedAt: now)
        let certificate = CertificateRecord(id: "synthetic-certificate", name: "Public synthetic certificate", eventDate: now,
                                            tags: [], attachments: [attachment], createdAt: now, updatedAt: now)
        let folder = DocumentFolder(id: "synthetic-folder", libraryKind: .importantLiterature, name: "Public synthetic folder", createdAt: now, updatedAt: now)
        let document = ManagedDocument(id: "synthetic-document", folderID: folder.id, originalName: "public.txt", displayName: "Public synthetic document",
                                      storedName: "public.txt", fileExtension: "txt", tags: [], byteCount: Int64(bytes.count), uploadedAt: now, updatedAt: now,
                                      contentText: "Public synthetic attachment bytes", contentIndexedAt: now)
        var library = PersistedLibrary(), active: URL?, recordID: String
        switch kind {
        case .work, .workAttachment, .noPayload:
            library.existingWorks = [work]; recordID = kind == .workAttachment ? attachment.id : work.id
            if kind != .noPayload { active = LibraryPaths.attachments.appendingPathComponent(work.id).appendingPathComponent(attachment.storedName) }
        case .certificate, .certificateAttachment:
            library.certificates = [certificate]; recordID = kind == .certificateAttachment ? attachment.id : certificate.id
            active = LibraryPaths.certificateAttachments.appendingPathComponent(certificate.id).appendingPathComponent(attachment.storedName)
        case .document, .folder:
            library.documentFolders = [folder]; library.managedDocuments = [document]; recordID = kind == .folder ? folder.id : document.id
            active = LibraryPaths.managedDocuments.appendingPathComponent(folder.libraryKind.rawValue).appendingPathComponent(folder.id).appendingPathComponent(document.storedName)
        }
        if let active {
            try FileManager.default.createDirectory(at: active.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: active)
        }
        // Multiple set entries make accidental array-order comparisons visible.
        library.rewardCity.unlockedPlotIDs.formUnion(["fixture-plot-a", "fixture-plot-b"])
        library.rewardCity.rewardedWorkIDs.formUnion(["fixture-work-a", "fixture-work-b"])
        try repo.disk.saveLibrary(library)
        let store = PaperStore(repository: repo)
        try require(!store.libraryLoadFailed, "Fixture failed to load")
        return Fixture(kind: kind, repo: repo, store: store, active: active, recordID: recordID)
    }
    static func setFault(_ name: String, _ fixture: Fixture) {
        fixture.repo.failure = name == "before" ? .beforeSave : name == "after" ? .afterSave : nil
    }
    static func lifecycle(kind: Kind, operation: String, fault: String) throws {
        let f = try fixture(kind)
        var trash: TrashItem?
        if operation == "restore" {
            f.delete()
            trash = f.store.trashItems.first
            try require(trash != nil && !f.activeRecordExists(durable(f.repo)), "Successful setup delete did not commit")
        }
        setFault(fault, f)
        if operation == "delete" { f.delete() } else { f.store.restoreTrashItem(id: trash!.id) }
        let disk = try durable(f.repo)
        let committed = fault != "before"
        let expectedActive = operation == "restore" ? committed : !committed
        try require(f.activeRecordExists(disk) == expectedActive && f.memoryActive() == expectedActive, "Memory/disk differ after save outcome")
        try require(disk.trashItems.isEmpty == expectedActive, "Trash metadata is inconsistent with active state")
        if fault != "success" { try require(f.store.lastError != nil, "Injected write exception was hidden") }
        if let active = f.active {
            let sourceData = try? Data(contentsOf: active)
            if operation == "delete" {
                let copy = try disk.trashItems.first.map(f.payload) ?? f.orphanSafetyPayload()
                try require(try Data(contentsOf: copy) == bytes, "Trash copy missing or changed")
                try require((sourceData == bytes) == (fault != "success"), "Original deletion source was lost on uncertain commit or retained on success")
            } else {
                try require(sourceData == bytes, "Restored destination missing after failed or successful commit")
                let payloadExists = FileManager.default.fileExists(atPath: f.payload(trash!).path)
                try require(payloadExists == (fault != "success"), "Restore deleted its safety source before confirmed commit")
                if payloadExists { try require(try Data(contentsOf: f.payload(trash!)) == bytes, "Retained restore payload changed") }
            }
        }
        if fault == "after" {
            try require(!f.store.libraryLoadFailed, "Readable committed exception unnecessarily blocked library")
            try f.store.saveThrowing()
            try require(f.activeRecordExists(durable(f.repo)) == expectedActive, "Post-rename exception did not refresh repository CAS baseline")
        }
    }
    static func purge(operation: String, fault: String) throws {
        let f = try fixture(.work); f.delete()
        let item = f.store.trashItems[0], payload = f.payload(item)
        f.store.trashItems[0].deletedAt = Date().addingTimeInterval(-31 * 86400)
        try f.store.saveThrowing()
        let unknown = TrashStore.storageURL.appendingPathComponent("unknown-safety-copy/payload")
        try FileManager.default.createDirectory(at: unknown.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: unknown)
        setFault(fault, f)
        if operation == "empty" { f.store.emptyTrash() }
        else if operation == "expiry" { f.store.purgeExpiredTrash() }
        else { f.store.permanentlyDeleteTrashItem(id: item.id) }
        let disk = try durable(f.repo)
        try require(disk.trashItems.isEmpty == (fault != "before"), "Purge metadata did not match actual commit outcome")
        try require(f.store.trashItems.isEmpty == disk.trashItems.isEmpty, "Purge memory disagrees with durable records")
        try require(FileManager.default.fileExists(atPath: payload.path) == (fault != "success"), "Purge removed safety payload on unconfirmed commit")
        try require(try Data(contentsOf: unknown) == bytes, "Purge or empty deleted unknown safety material")
        if fault != "success" { try require(f.store.lastError != nil, "Purge write exception was hidden") }
    }
    static func missing(kind: Kind, operation: String) throws {
        let f = try fixture(kind)
        if operation == "delete" {
            try FileManager.default.removeItem(at: f.active!)
            let before = try Data(contentsOf: f.repo.libraryURL)
            f.delete()
            try require(try Data(contentsOf: f.repo.libraryURL) == before && f.memoryActive(), "Missing declared payload became a deletion")
        } else {
            f.delete(); let item = f.store.trashItems[0]
            try FileManager.default.removeItem(at: f.payload(item))
            let before = try Data(contentsOf: f.repo.libraryURL)
            f.store.restoreTrashItem(id: item.id)
            try require(try Data(contentsOf: f.repo.libraryURL) == before && !f.memoryActive(), "Missing declared payload became a restoration")
        }
        try require(f.store.lastError != nil, "Missing declared payload was not reported")
    }
    static func edge(_ name: String) throws {
        let f = try fixture(name == "folder-conflict" ? .folder : .work)
        switch name {
        case "unsaved-memory":
            let now = Date()
            f.store.projects.append(ResearchProject(id: "pending-memory", title: "Earlier unsaved edit", content: "synthetic", steps: [], createdAt: now, updatedAt: now))
            f.repo.failure = .beforeSave; f.delete()
            try require(f.store.projects.contains { $0.id == "pending-memory" }, "Pre-existing unsaved edit was discarded")
            try require(try !durable(f.repo).projects.contains { $0.id == "pending-memory" }, "Failed transaction unexpectedly saved earlier edit")
            try require(try f.memoryActive() && Data(contentsOf: f.active!) == bytes, "Failed operation was not rolled back independently")
        case "external-cas":
            var external = try durable(f.repo); let now = Date()
            external.projects.append(ResearchProject(id: "external-record", title: "External committed record", content: "synthetic", steps: [], createdAt: now, updatedAt: now))
            try writeExternal(external, f.repo); f.delete()
            let changed = try Data(contentsOf: f.repo.libraryURL)
            try require(f.store.libraryLoadFailed, "CAS conflict rebased stale memory as writable")
            f.store.save()
            try require(try Data(contentsOf: f.repo.libraryURL) == changed && durable(f.repo).projects.contains { $0.id == "external-record" }, "Later save overwrote external committed record")
            try require(try Data(contentsOf: f.active!) == bytes && Data(contentsOf: f.orphanSafetyPayload()) == bytes, "CAS conflict lost one safety copy")
        case "unreadable-after":
            f.repo.failure = .unreadableAfterSave; f.delete()
            let changed = try Data(contentsOf: f.repo.libraryURL)
            try require(f.store.libraryLoadFailed && f.memoryActive(), "Unreadable result was not write protected with original memory retained")
            f.store.save()
            try require(try Data(contentsOf: f.repo.libraryURL) == changed, "Unreadable library was overwritten")
            try require(try Data(contentsOf: f.active!) == bytes && Data(contentsOf: f.orphanSafetyPayload()) == bytes, "Unreadable result lost one safety copy")
        case "changed-source-cleanup":
            let changed = Data("Public synthetic newer source bytes".utf8)
            f.repo.afterSave = { try changed.write(to: f.active!) }; f.delete()
            let disk = try durable(f.repo)
            try require(!f.activeRecordExists(disk) && disk.trashItems.count == 1, "Cleanup conflict rolled back committed metadata")
            try require(try Data(contentsOf: f.active!) == changed && Data(contentsOf: f.payload(disk.trashItems[0])) == bytes, "Cleanup deleted changed source or verified copy")
            try require(f.store.lastError?.contains("已提交") == true, "Cleanup failure did not report committed metadata and residual copy")
        case "copy-existing-final", "copy-new-final":
            f.delete(); let item = f.store.trashItems[0]
            let before = try Data(contentsOf: f.repo.libraryURL)
            let newer = Data("Public synthetic concurrent final target".utf8)
            if name == "copy-existing-final" {
                try FileManager.default.createDirectory(at: f.active!.deletingLastPathComponent(), withIntermediateDirectories: true)
                try newer.write(to: f.active!)
            } else {
                ResearchTrashCopyFault.handler = { _, destination in
                    // Runs after production's absence check. The actual
                    // FileManager.copyItem then fails on this new target.
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    try newer.write(to: destination.appendingPathComponent("public.txt"))
                }
            }
            f.store.restoreTrashItem(id: item.id)
            try require(try Data(contentsOf: f.repo.libraryURL) == before && !f.memoryActive(), "Copy conflict changed metadata")
            try require(try Data(contentsOf: f.active!) == newer, "Failed copy deleted the existing or concurrent final target")
            try require(try Data(contentsOf: f.payload(item)) == bytes, "Failed copy lost original trash payload")
            try require(f.store.lastError != nil && ResearchTrashCopyFault.calls == (name == "copy-new-final" ? 1 : 0), "Copy race was not exercised or reported")
        case "malformed-id":
            f.store.existingWorks[0].id = ".."
            try f.store.saveThrowing()
            let before = try Data(contentsOf: f.repo.libraryURL)
            f.store.moveWorkToTrash(f.store.existingWorks[0])
            try require(try Data(contentsOf: f.repo.libraryURL) == before && f.store.existingWorks.first?.id == "..", "Malformed path ID was committed or removed parent storage")
            try require(try Data(contentsOf: f.active!) == bytes && f.store.lastError != nil, "Malformed ID removed unrelated attachment")
        case "folder-conflict":
            let g = f; g.delete(); let item = g.store.trashItems[0]
            var conflicted = item.documents[0]; conflicted.folderID = "synthetic-other-folder"
            g.store.managedDocuments.append(conflicted); try g.store.saveThrowing()
            let before = try Data(contentsOf: g.repo.libraryURL)
            g.store.restoreTrashItem(id: item.id)
            try require(try Data(contentsOf: g.repo.libraryURL) == before && g.store.lastError != nil, "Folder conflict silently restored partial records")
            try require(try Data(contentsOf: g.payload(item)) == bytes, "Folder conflict lost original payload")
        case "symlink":
            let replacement = f.active!.deletingLastPathComponent().appendingPathComponent("synthetic-real.txt")
            try bytes.write(to: replacement); try FileManager.default.removeItem(at: f.active!)
            try FileManager.default.createSymbolicLink(at: f.active!, withDestinationURL: replacement)
            let before = try Data(contentsOf: f.repo.libraryURL); f.delete()
            try require(try Data(contentsOf: f.repo.libraryURL) == before && f.memoryActive() && f.store.lastError != nil, "Symlink payload was copied or committed")
            try require(try Data(contentsOf: replacement) == bytes, "Symlink target was modified")
        default: throw Failure(description: "Unknown edge case")
        }
    }
    static func main() {
        setbuf(stdout, nil)
        do {
            guard let root = ProcessInfo.processInfo.environment["GAO_WIDGET_STORE_TEST_ROOT"], root.hasPrefix("/private/tmp/"), root.hasSuffix(".noindex"),
                  ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"] == root + "/Data",
                  ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] == "1", CommandLine.arguments.count == 2 else { throw Failure(description: "Unsafe fixture") }
            UserDefaults.standard.set("zh-Hans", forKey: "gqns.language")
            let name = CommandLine.arguments[1], parts = name.split(separator: ".").map(String.init)
            if parts[0] == "edge" { try edge(parts[1]) }
            else if parts[0] == "purge" { try purge(operation: parts[1], fault: parts[2]) }
            else {
                guard let kind = Kind(rawValue: parts[0]) else { throw Failure(description: "Unknown fixture kind") }
                if parts[2] == "missing" { try missing(kind: kind, operation: parts[1]) }
                else { try lifecycle(kind: kind, operation: parts[1], fault: parts[2]) }
            }
            print("PASS Trash \(name): \(assertions) targeted assertions; synthetic files only")
        } catch { fputs("FAIL Trash persistence: \(error)\n", stderr); exit(1) }
    }
}
