import Foundation
import Darwin

// MARK: - TrashStore：回收站状态与 TrashStorage 文件操作
//
// 拥有回收站条目列表、最近删除标记与删除提示，以及 TrashStorage 目录下的全部
// 文件搬运（移入 payload、恢复 payload、彻底删除、过期清理）。跨集合的恢复编排
// （恢复论文/成果/文件夹等到各自的属主集合）由下方 PaperStore 协调扩展完成，
// TrashStore 不反向持有 PaperStore，只通过 persist/errorHandler 回调单向通信。

private enum TrashError: LocalizedError {
    case conflict
    case missingParent
    case missingPayload
    case unsafePayload
    case changedPayload

    var errorDescription: String? {
        switch self {
        case .conflict: AppLocalization.text("原位置已存在同一条目，请先处理冲突。")
        case .missingParent: AppLocalization.text("原记录或文件夹不存在，请先恢复上级条目。")
        case .missingPayload: AppLocalization.text("记录声明的附件缺失或无法读取，已停止操作并保留原资料。")
        case .unsafePayload: AppLocalization.text("附件目录含无法安全核验的项目，已停止操作并保留原资料。")
        case .changedPayload: AppLocalization.text("附件在核验或复制后发生变化；已停止清理并保留资料和可恢复副本。")
        }
    }
}

@MainActor
final class TrashStore: ObservableObject {
    @Published var items: [TrashItem] = []
    @Published var lastDeletedTrashID: String?
    @Published var deletionMessage = ""

    var transaction: ((() throws -> Void) throws -> Void)?
    var errorHandler: (String) -> Void = { _ in }

    static let storageURL = LibraryPaths.trashStorage

    var orderedItems: [TrashItem] {
        items.sorted { $0.deletedAt > $1.deletedAt }
    }

    func trashDirectory(_ id: String) -> URL {
        Self.storageURL.appendingPathComponent(id, isDirectory: true)
    }

    func registerDeletion(_ item: TrashItem) {
        items.append(item)
        lastDeletedTrashID = item.id
        deletionMessage = AppLocalization.format("“%@”已移到回收站", item.title)
    }

    func withTransaction(_ changes: () throws -> Void) throws {
        guard let transaction else { throw ResearchDocumentImportError.unavailableLibrary }
        try transaction(changes)
    }

    private func validateComponent(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"),
              !value.contains("\\"), !value.utf8.contains(0) else { throw TrashError.unsafePayload }
    }

    func validatePayloadIdentifiers(_ item: TrashItem) throws {
        try validateComponent(item.id)
        switch item.kind {
        case .work:
            guard let work = item.work else { throw TrashError.missingParent }
            try validateComponent(work.id)
            for attachment in work.attachments { try validateComponent(attachment.storedName) }
        case .certificate:
            guard let record = item.certificate else { throw TrashError.missingParent }
            try validateComponent(record.id)
            for attachment in record.attachments { try validateComponent(attachment.storedName) }
        case .documentFolder:
            guard let folder = item.documentFolder else { throw TrashError.missingParent }
            try validateComponent(folder.id)
            for document in item.documents { try validateComponent(document.folderID); try validateComponent(document.storedName) }
        case .document:
            guard let document = item.documents.first else { throw TrashError.missingParent }
            try validateComponent(document.folderID); try validateComponent(document.storedName)
        case .workAttachment, .certificateAttachment:
            guard let parent = item.parentID, let attachment = item.attachment else { throw TrashError.missingParent }
            try validateComponent(parent); try validateComponent(attachment.storedName)
        case .submission, .project, .funding: break // IDs here never form payload paths.
        }
    }

    private func validatePayloadPath(_ url: URL) throws {
        guard url.isFileURL, !url.pathComponents.contains("."), !url.pathComponents.contains("..") else { throw TrashError.unsafePayload }
        var ancestor = url.deletingLastPathComponent()
        while ancestor.path != "/" {
            if let values = try attributesIfPresent(ancestor) {
                guard values[.type] as? FileAttributeType == .typeDirectory else { throw TrashError.unsafePayload }
            }
            ancestor = ancestor.deletingLastPathComponent()
        }
    }

    /// Keep the original until the whole library commit has been confirmed.
    func copyPayloadIntoTrash(_ source: URL, trashID: String, required: Bool = false,
                              requiredChildren: [String] = []) throws {
        try copyPayload(source, to: trashDirectory(trashID).appendingPathComponent("payload"),
                        required: required, requiredChildren: requiredChildren)
    }

    func restorePayload(_ trashID: String, to destination: URL, required: Bool = false,
                        requiredChildren: [String] = []) throws {
        try copyPayload(trashDirectory(trashID).appendingPathComponent("payload"), to: destination,
                        required: required, requiredChildren: requiredChildren)
    }

    private func attributesIfPresent(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
    }

    /// Every regular file is read through the existing no-follow, owner-checked
    /// descriptor helper. Directory markers also preserve empty directories.
    private func payloadInventory(_ root: URL) throws -> [String: String] {
        try validatePayloadPath(root)
        var result: [String: String] = [:]
        func visit(_ url: URL, relative: String) throws {
            guard let values = try attributesIfPresent(url) else { throw TrashError.missingPayload }
            switch values[.type] as? FileAttributeType {
            case .typeDirectory:
                guard (values[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else { throw TrashError.unsafePayload }
                result[relative + "/"] = "directory"
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent)
                }
            case .typeRegular:
                let fingerprint = try GaoActionFileAccess.fingerprint(at: url)
                result[relative] = "\(fingerprint.byteCount):\(fingerprint.sha256)"
            default: throw TrashError.unsafePayload
            }
        }
        try visit(root, relative: "")
        return result
    }

    private func syncPayload(_ url: URL) throws {
        guard let values = try attributesIfPresent(url) else { throw TrashError.missingPayload }
        let kind = values[.type] as? FileAttributeType
        guard kind == .typeDirectory || kind == .typeRegular else { throw TrashError.unsafePayload }
        if kind == .typeDirectory {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try syncPayload(child) }
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (kind == .typeDirectory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw TrashError.unsafePayload }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw TrashError.unsafePayload }
    }

    private func copyPayload(_ source: URL, to destination: URL, required: Bool,
                             requiredChildren: [String]) throws {
        try validatePayloadPath(source); try validatePayloadPath(destination)
        guard try attributesIfPresent(source) != nil else {
            guard !required, requiredChildren.isEmpty else { throw TrashError.missingPayload }
            return
        }
        let before = try payloadInventory(source)
        for name in requiredChildren {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  before[name] != nil else { throw TrashError.missingPayload }
        }
        if try attributesIfPresent(destination) != nil {
            // A previous uncertain save deliberately retained both copies.
            guard try payloadInventory(destination) == before else { throw TrashError.conflict }
        } else {
            try GaoActionFileAccess.ensurePrivateDirectory(at: destination.deletingLastPathComponent())
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                guard try payloadInventory(destination) == before else { throw TrashError.changedPayload }
            } catch {
                // A concurrent writer could have created this final path after
                // our absence check. Do not delete a destination whose identity
                // we cannot prove. Retry accepts only a complete matching copy;
                // incomplete or changed payloads remain an explicit conflict.
                throw error
            }
        }
        guard try payloadInventory(source) == before else { throw TrashError.changedPayload }
        try syncPayload(destination)
        let parent = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw TrashError.unsafePayload }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw TrashError.unsafePayload }
    }

    func finishDeletionCopy(_ source: URL, trashID: String) throws {
        try validatePayloadPath(source)
        guard try attributesIfPresent(source) != nil else { return }
        let destination = trashDirectory(trashID).appendingPathComponent("payload")
        guard try payloadInventory(source) == payloadInventory(destination) else { throw TrashError.changedPayload }
        try FileManager.default.removeItem(at: source)
    }

    func finishRestoration(_ id: String, destination: URL?) throws {
        let source = trashDirectory(id).appendingPathComponent("payload")
        if try attributesIfPresent(source) != nil {
            guard let destination, try payloadInventory(source) == payloadInventory(destination) else { throw TrashError.changedPayload }
        }
        try removePayloadDirectory(id)
    }

    func removePayloadDirectory(_ id: String) throws {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\") else { throw TrashError.unsafePayload }
        let directory = trashDirectory(id)
        guard let values = try attributesIfPresent(directory) else { return }
        guard values[.type] as? FileAttributeType == .typeDirectory else { throw TrashError.unsafePayload }
        try FileManager.default.removeItem(at: directory)
    }

    func permanentlyDeleteTrashItem(id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        var committed = false
        do {
            if let item = items.first(where: { $0.id == id }) { try validatePayloadIdentifiers(item) }
            try withTransaction {
                items.removeAll { $0.id == id }
                if lastDeletedTrashID == id { lastDeletedTrashID = nil }
            }
            committed = true
            try removePayloadDirectory(id)
        } catch {
            errorHandler(AppLocalization.format(committed ? "删除记录已提交；遗留安全副本未能清理：%@" : "彻底删除未完整确认，未执行后续附件清理：%@", error.localizedDescription))
        }
    }

    func emptyTrash() {
        var committed = false
        do {
            let ids = items.map(\.id)
            for item in items { try validatePayloadIdentifiers(item) }
            try withTransaction {
                items.removeAll()
                lastDeletedTrashID = nil
            }
            committed = true
            // Unknown/uncommitted safety copies are not part of this request.
            for id in ids { try removePayloadDirectory(id) }
        } catch {
            errorHandler(AppLocalization.format(committed ? "清空记录已提交；遗留安全副本未能清理：%@" : "清空回收站未完整确认，未执行后续附件清理：%@", error.localizedDescription))
        }
    }

    func purgeExpiredTrash(retentionDays: Int = 30) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast
        for item in items where item.deletedAt < cutoff {
            permanentlyDeleteTrashItem(id: item.id)
        }
    }
}

// MARK: - PaperStore 回收站协调扩展
//
// 移入/恢复需要同时改动属主集合（papers/existingWorks/projects/...，部分归属
// DocumentLibraryStore）与 TrashStore，这层编排留在 PaperStore 门面里。

@MainActor
extension PaperStore {
    static let trashStorageURL = TrashStore.storageURL

    /// 回收站条目由 TrashStore 持有；读写经此转发，语义与原 @Published 存储一致。
    var trashItems: [TrashItem] {
        get { trashStore.items }
        set { trashStore.items = newValue }
    }

    var lastDeletedTrashID: String? {
        get { trashStore.lastDeletedTrashID }
        set { trashStore.lastDeletedTrashID = newValue }
    }

    var deletionMessage: String {
        get { trashStore.deletionMessage }
        set { trashStore.deletionMessage = newValue }
    }

    var orderedTrashItems: [TrashItem] {
        trashStore.orderedItems
    }

    private func commitDeletion(_ item: TrashItem, payload: URL? = nil, required: Bool = false,
                                requiredChildren: [String] = [], removing: () -> Void) {
        var committed = false
        do {
            try trashStore.withTransaction {
                try trashStore.validatePayloadIdentifiers(item)
                if let payload {
                    try trashStore.copyPayloadIntoTrash(payload, trashID: item.id, required: required,
                                                        requiredChildren: requiredChildren)
                }
                removing()
                trashStore.registerDeletion(item)
            }
            committed = true
            if let payload { try trashStore.finishDeletionCopy(payload, trashID: item.id) }
        } catch {
            lastError = AppLocalization.format(committed ? "删除记录已提交；旧位置安全副本未能清理：%@" : "移入回收站未完整确认：%@；已停止后续清理，请核对原记录及现有附件副本。", error.localizedDescription)
        }
    }

    func movePaperToTrash(_ paper: PaperRecord) {
        guard let paper = papers.first(where: { $0.id == paper.id }) else { return }
        let item = TrashItem(id: UUID().uuidString, kind: .submission, title: paper.title, deletedAt: Date(), paper: paper)
        commitDeletion(item) { papers.removeAll { $0.id == paper.id } }
    }

    func moveWorkToTrash(_ work: ExistingWork) {
        guard let work = existingWorks.first(where: { $0.id == work.id }) else { return }
        let item = TrashItem(id: UUID().uuidString, kind: .work, title: work.title, deletedAt: Date(), work: work)
        commitDeletion(item, payload: Self.attachmentsURL.appendingPathComponent(work.id, isDirectory: true),
                       requiredChildren: work.attachments.map(\.storedName)) {
            existingWorks.removeAll { $0.id == work.id }
        }
    }

    func moveProjectToTrash(_ project: ResearchProject) {
        guard let project = projects.first(where: { $0.id == project.id }) else { return }
        let item = TrashItem(id: UUID().uuidString, kind: .project, title: project.title, deletedAt: Date(), project: project)
        commitDeletion(item) { projects.removeAll { $0.id == project.id } }
    }

    func moveCertificateToTrash(_ record: CertificateRecord) {
        guard let record = certificates.first(where: { $0.id == record.id }) else { return }
        let item = TrashItem(id: UUID().uuidString, kind: .certificate, title: record.name, deletedAt: Date(), certificate: record)
        commitDeletion(item, payload: Self.certificateAttachmentsURL.appendingPathComponent(record.id, isDirectory: true),
                       requiredChildren: record.attachments.map(\.storedName)) {
            certificates.removeAll { $0.id == record.id }
        }
    }

    func moveFundingToTrash(_ record: FundingRecord) {
        guard let record = fundingRecords.first(where: { $0.id == record.id }) else { return }
        let item = TrashItem(id: UUID().uuidString, kind: .funding, title: record.name, deletedAt: Date(), funding: record)
        commitDeletion(item) { fundingRecords.removeAll { $0.id == record.id } }
    }

    func moveDocumentFolderToTrash(id: String) {
        guard let folder = documentFolders.first(where: { $0.id == id }) else { return }
        let documents = managedDocuments.filter { $0.folderID == id }
        let item = TrashItem(id: UUID().uuidString, kind: .documentFolder, title: folder.name,
                             deletedAt: Date(), documentFolder: folder, documents: documents)
        commitDeletion(item, payload: documentLibrary.folderURL(for: folder), requiredChildren: documents.map(\.storedName)) {
            managedDocuments.removeAll { $0.folderID == id }
            documentFolders.removeAll { $0.id == id }
        }
    }

    func moveDocumentToTrash(_ document: ManagedDocument) {
        guard let document = managedDocuments.first(where: { $0.id == document.id }) else { return }
        let item = TrashItem(id: UUID().uuidString, kind: .document, title: document.displayName,
                             deletedAt: Date(), documents: [document])
        commitDeletion(item, payload: managedDocumentURL(document), required: true) {
            managedDocuments.removeAll { $0.id == document.id }
            if let index = documentFolders.firstIndex(where: { $0.id == document.folderID }) {
                documentFolders[index].updatedAt = Date()
            }
        }
    }

    func moveWorkAttachmentToTrash(_ attachment: WorkAttachment, workID: String) {
        guard let index = existingWorks.firstIndex(where: { $0.id == workID }),
              let attachment = existingWorks[index].attachments.first(where: { $0.id == attachment.id }) else { return }
        let item = TrashItem(id: UUID().uuidString, kind: .workAttachment, title: attachment.originalName,
                             deletedAt: Date(), attachment: attachment, parentID: workID)
        let source = Self.attachmentsURL.appendingPathComponent(workID, isDirectory: true).appendingPathComponent(attachment.storedName)
        commitDeletion(item, payload: source, required: true) {
            existingWorks[index].attachments.removeAll { $0.id == attachment.id }
            existingWorks[index].updatedAt = Date()
        }
    }

    func moveCertificateAttachmentToTrash(_ attachment: WorkAttachment, recordID: String) {
        guard let index = certificates.firstIndex(where: { $0.id == recordID }),
              let attachment = certificates[index].attachments.first(where: { $0.id == attachment.id }) else { return }
        let item = TrashItem(id: UUID().uuidString, kind: .certificateAttachment, title: attachment.originalName,
                             deletedAt: Date(), attachment: attachment, parentID: recordID)
        let source = Self.certificateAttachmentsURL.appendingPathComponent(recordID, isDirectory: true).appendingPathComponent(attachment.storedName)
        commitDeletion(item, payload: source, required: true) {
            certificates[index].attachments.removeAll { $0.id == attachment.id }
            certificates[index].updatedAt = Date()
        }
    }

    func undoLastDeletion() {
        guard let id = lastDeletedTrashID else { return }
        restoreTrashItem(id: id)
    }

    func restoreTrashItem(id: String) {
        guard let item = trashItems.first(where: { $0.id == id }) else { return }
        var restoredDestination: URL?
        var committed = false
        do {
            try trashStore.validatePayloadIdentifiers(item)
            try trashStore.withTransaction {
            switch item.kind {
            case .submission:
                guard let paper = item.paper, !papers.contains(where: { $0.id == paper.id }) else {
                    throw TrashError.conflict
                }
                papers.append(paper)
            case .work:
                guard let work = item.work, !existingWorks.contains(where: { $0.id == work.id }) else {
                    throw TrashError.conflict
                }
                restoredDestination = Self.attachmentsURL.appendingPathComponent(work.id, isDirectory: true)
                try trashStore.restorePayload(item.id, to: restoredDestination!, requiredChildren: work.attachments.map(\.storedName))
                existingWorks.append(work)
            case .project:
                guard let project = item.project, !projects.contains(where: { $0.id == project.id }) else {
                    throw TrashError.conflict
                }
                projects.append(project)
            case .documentFolder:
                guard let folder = item.documentFolder,
                      !documentFolders.contains(where: { $0.id == folder.id }),
                      !item.documents.contains(where: { document in managedDocuments.contains(where: { $0.id == document.id }) }) else { throw TrashError.conflict }
                restoredDestination = documentLibrary.folderURL(for: folder)
                try trashStore.restorePayload(item.id, to: restoredDestination!, requiredChildren: item.documents.map(\.storedName))
                documentFolders.append(folder)
                managedDocuments.append(contentsOf: item.documents)
            case .document:
                guard let document = item.documents.first,
                      documentFolders.contains(where: { $0.id == document.folderID }),
                      !managedDocuments.contains(where: { $0.id == document.id }) else { throw TrashError.missingParent }
                restoredDestination = managedDocumentURL(document)
                try trashStore.restorePayload(item.id, to: restoredDestination!, required: true)
                managedDocuments.append(document)
            case .certificate:
                guard let record = item.certificate, !certificates.contains(where: { $0.id == record.id }) else {
                    throw TrashError.conflict
                }
                restoredDestination = Self.certificateAttachmentsURL.appendingPathComponent(record.id, isDirectory: true)
                try trashStore.restorePayload(item.id, to: restoredDestination!, requiredChildren: record.attachments.map(\.storedName))
                certificates.append(record)
            case .funding:
                guard let record = item.funding, !fundingRecords.contains(where: { $0.id == record.id }) else {
                    throw TrashError.conflict
                }
                fundingRecords.append(record)
            case .workAttachment:
                guard let attachment = item.attachment, let parentID = item.parentID,
                      let index = existingWorks.firstIndex(where: { $0.id == parentID }) else { throw TrashError.missingParent }
                guard !existingWorks[index].attachments.contains(where: { $0.id == attachment.id || $0.storedName == attachment.storedName }) else { throw TrashError.conflict }
                let destination = Self.attachmentsURL
                    .appendingPathComponent(parentID, isDirectory: true)
                    .appendingPathComponent(attachment.storedName)
                restoredDestination = destination
                try trashStore.restorePayload(item.id, to: destination, required: true)
                existingWorks[index].attachments.append(attachment)
            case .certificateAttachment:
                guard let attachment = item.attachment, let parentID = item.parentID,
                      let index = certificates.firstIndex(where: { $0.id == parentID }) else { throw TrashError.missingParent }
                guard !certificates[index].attachments.contains(where: { $0.id == attachment.id || $0.storedName == attachment.storedName }) else { throw TrashError.conflict }
                let destination = Self.certificateAttachmentsURL
                    .appendingPathComponent(parentID, isDirectory: true)
                    .appendingPathComponent(attachment.storedName)
                restoredDestination = destination
                try trashStore.restorePayload(item.id, to: destination, required: true)
                certificates[index].attachments.append(attachment)
            }
            trashItems.removeAll { $0.id == item.id }
            if lastDeletedTrashID == item.id { lastDeletedTrashID = nil }
            deletionMessage = AppLocalization.format("已恢复“%@”", item.title)
            }
            committed = true
            try trashStore.finishRestoration(item.id, destination: restoredDestination)
        } catch {
            lastError = AppLocalization.format(committed ? "“%@”的恢复记录已提交；回收站安全副本未能清理：%@" : "恢复“%@”未完整确认，未执行后续附件清理：%@", item.title, error.localizedDescription)
        }
    }

    func permanentlyDeleteTrashItem(id: String) {
        trashStore.permanentlyDeleteTrashItem(id: id)
    }

    func emptyTrash() {
        trashStore.emptyTrash()
    }

    func purgeExpiredTrash(retentionDays: Int = 30) {
        trashStore.purgeExpiredTrash(retentionDays: retentionDays)
    }
}
