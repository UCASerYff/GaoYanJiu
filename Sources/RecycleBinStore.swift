import Foundation

// MARK: - TrashStore：回收站状态与 TrashStorage 文件操作
//
// 拥有回收站条目列表、最近删除标记与删除提示，以及 TrashStorage 目录下的全部
// 文件搬运（移入 payload、恢复 payload、彻底删除、过期清理）。跨集合的恢复编排
// （恢复论文/成果/文件夹等到各自的属主集合）由下方 PaperStore 协调扩展完成，
// TrashStore 不反向持有 PaperStore，只通过 persist/errorHandler 回调单向通信。

private enum TrashError: LocalizedError {
    case conflict
    case missingParent

    var errorDescription: String? {
        switch self {
        case .conflict: AppLocalization.text("原位置已存在同一条目，请先处理冲突。")
        case .missingParent: AppLocalization.text("原记录或文件夹不存在，请先恢复上级条目。")
        }
    }
}

@MainActor
final class TrashStore: ObservableObject {
    @Published var items: [TrashItem] = []
    @Published var lastDeletedTrashID: String?
    @Published var deletionMessage = ""

    var persist: () -> Void = {}
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
        persist()
    }

    func movePayloadIntoTrashIfPresent(_ source: URL, trashID: String) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return }
        let directory = trashDirectory(trashID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("payload", isDirectory: source.hasDirectoryPath)
        try fileManager.moveItem(at: source, to: destination)
    }

    func restorePayload(_ trashID: String, to destination: URL) throws {
        let fileManager = FileManager.default
        let source = trashDirectory(trashID).appendingPathComponent("payload")
        guard fileManager.fileExists(atPath: source.path) else { return }
        guard !fileManager.fileExists(atPath: destination.path) else { throw TrashError.conflict }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
    }

    func removePayloadDirectory(_ id: String) {
        try? FileManager.default.removeItem(at: trashDirectory(id))
    }

    func permanentlyDeleteTrashItem(id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        do {
            let directory = trashDirectory(id)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            items.removeAll { $0.id == id }
            if lastDeletedTrashID == id { lastDeletedTrashID = nil }
            persist()
        } catch {
            errorHandler(AppLocalization.format("无法彻底删除：%@", error.localizedDescription))
        }
    }

    func emptyTrash() {
        do {
            if FileManager.default.fileExists(atPath: Self.storageURL.path) {
                try FileManager.default.removeItem(at: Self.storageURL)
            }
            items.removeAll()
            lastDeletedTrashID = nil
            persist()
        } catch {
            errorHandler(AppLocalization.format("无法清空回收站：%@", error.localizedDescription))
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

    func movePaperToTrash(_ paper: PaperRecord) {
        guard papers.contains(where: { $0.id == paper.id }) else { return }
        let item = TrashItem(
            id: UUID().uuidString,
            kind: .submission,
            title: paper.title,
            deletedAt: Date(),
            paper: paper
        )
        papers.removeAll { $0.id == paper.id }
        trashStore.registerDeletion(item)
    }

    func moveWorkToTrash(_ work: ExistingWork) {
        guard existingWorks.contains(where: { $0.id == work.id }) else { return }
        let item = TrashItem(
            id: UUID().uuidString,
            kind: .work,
            title: work.title,
            deletedAt: Date(),
            work: work
        )
        do {
            try trashStore.movePayloadIntoTrashIfPresent(
                Self.attachmentsURL.appendingPathComponent(work.id, isDirectory: true),
                trashID: item.id
            )
            existingWorks.removeAll { $0.id == work.id }
            trashStore.registerDeletion(item)
        } catch {
            lastError = AppLocalization.format("无法移入回收站：%@", error.localizedDescription)
        }
    }

    func moveProjectToTrash(_ project: ResearchProject) {
        guard projects.contains(where: { $0.id == project.id }) else { return }
        let item = TrashItem(
            id: UUID().uuidString,
            kind: .project,
            title: project.title,
            deletedAt: Date(),
            project: project
        )
        projects.removeAll { $0.id == project.id }
        trashStore.registerDeletion(item)
    }

    func moveCertificateToTrash(_ record: CertificateRecord) {
        guard certificates.contains(where: { $0.id == record.id }) else { return }
        let item = TrashItem(
            id: UUID().uuidString,
            kind: .certificate,
            title: record.name,
            deletedAt: Date(),
            certificate: record
        )
        do {
            try trashStore.movePayloadIntoTrashIfPresent(
                Self.certificateAttachmentsURL.appendingPathComponent(record.id, isDirectory: true),
                trashID: item.id
            )
            certificates.removeAll { $0.id == record.id }
            trashStore.registerDeletion(item)
        } catch {
            lastError = AppLocalization.format("无法移入回收站：%@", error.localizedDescription)
        }
    }

    func moveFundingToTrash(_ record: FundingRecord) {
        guard fundingRecords.contains(where: { $0.id == record.id }) else { return }
        let item = TrashItem(
            id: UUID().uuidString,
            kind: .funding,
            title: record.name,
            deletedAt: Date(),
            funding: record
        )
        fundingRecords.removeAll { $0.id == record.id }
        trashStore.registerDeletion(item)
    }

    func moveDocumentFolderToTrash(id: String) {
        guard let folder = documentFolders.first(where: { $0.id == id }) else { return }
        let documents = managedDocuments.filter { $0.folderID == id }
        let item = TrashItem(
            id: UUID().uuidString,
            kind: .documentFolder,
            title: folder.name,
            deletedAt: Date(),
            documentFolder: folder,
            documents: documents
        )
        do {
            try trashStore.movePayloadIntoTrashIfPresent(documentLibrary.folderURL(for: folder), trashID: item.id)
            managedDocuments.removeAll { $0.folderID == id }
            documentFolders.removeAll { $0.id == id }
            trashStore.registerDeletion(item)
        } catch {
            lastError = AppLocalization.format("无法移入回收站：%@", error.localizedDescription)
        }
    }

    func moveDocumentToTrash(_ document: ManagedDocument) {
        guard managedDocuments.contains(where: { $0.id == document.id }) else { return }
        let item = TrashItem(
            id: UUID().uuidString,
            kind: .document,
            title: document.displayName,
            deletedAt: Date(),
            documents: [document]
        )
        do {
            try trashStore.movePayloadIntoTrashIfPresent(managedDocumentURL(document), trashID: item.id)
            managedDocuments.removeAll { $0.id == document.id }
            if let index = documentFolders.firstIndex(where: { $0.id == document.folderID }) {
                documentFolders[index].updatedAt = Date()
            }
            trashStore.registerDeletion(item)
        } catch {
            lastError = AppLocalization.format("无法移入回收站：%@", error.localizedDescription)
        }
    }

    func moveWorkAttachmentToTrash(_ attachment: WorkAttachment, workID: String) {
        guard let index = existingWorks.firstIndex(where: { $0.id == workID }) else { return }
        let item = TrashItem(
            id: UUID().uuidString,
            kind: .workAttachment,
            title: attachment.originalName,
            deletedAt: Date(),
            attachment: attachment,
            parentID: workID
        )
        do {
            let source = Self.attachmentsURL
                .appendingPathComponent(workID, isDirectory: true)
                .appendingPathComponent(attachment.storedName)
            try trashStore.movePayloadIntoTrashIfPresent(source, trashID: item.id)
            existingWorks[index].attachments.removeAll { $0.id == attachment.id }
            existingWorks[index].updatedAt = Date()
            trashStore.registerDeletion(item)
        } catch {
            lastError = AppLocalization.format("无法移入回收站：%@", error.localizedDescription)
        }
    }

    func moveCertificateAttachmentToTrash(_ attachment: WorkAttachment, recordID: String) {
        guard let index = certificates.firstIndex(where: { $0.id == recordID }) else { return }
        let item = TrashItem(
            id: UUID().uuidString,
            kind: .certificateAttachment,
            title: attachment.originalName,
            deletedAt: Date(),
            attachment: attachment,
            parentID: recordID
        )
        do {
            let source = Self.certificateAttachmentsURL
                .appendingPathComponent(recordID, isDirectory: true)
                .appendingPathComponent(attachment.storedName)
            try trashStore.movePayloadIntoTrashIfPresent(source, trashID: item.id)
            certificates[index].attachments.removeAll { $0.id == attachment.id }
            certificates[index].updatedAt = Date()
            trashStore.registerDeletion(item)
        } catch {
            lastError = AppLocalization.format("无法移入回收站：%@", error.localizedDescription)
        }
    }

    func undoLastDeletion() {
        guard let id = lastDeletedTrashID else { return }
        restoreTrashItem(id: id)
    }

    func restoreTrashItem(id: String) {
        guard let item = trashItems.first(where: { $0.id == id }) else { return }
        do {
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
                try trashStore.restorePayload(item.id, to: Self.attachmentsURL.appendingPathComponent(work.id, isDirectory: true))
                existingWorks.append(work)
            case .project:
                guard let project = item.project, !projects.contains(where: { $0.id == project.id }) else {
                    throw TrashError.conflict
                }
                projects.append(project)
            case .documentFolder:
                guard let folder = item.documentFolder,
                      !documentFolders.contains(where: { $0.id == folder.id }) else { throw TrashError.conflict }
                try trashStore.restorePayload(item.id, to: documentLibrary.folderURL(for: folder))
                documentFolders.append(folder)
                managedDocuments.append(contentsOf: item.documents.filter { candidate in
                    !managedDocuments.contains(where: { $0.id == candidate.id })
                })
            case .document:
                guard let document = item.documents.first,
                      documentFolders.contains(where: { $0.id == document.folderID }),
                      !managedDocuments.contains(where: { $0.id == document.id }) else { throw TrashError.missingParent }
                try trashStore.restorePayload(item.id, to: managedDocumentURL(document))
                managedDocuments.append(document)
            case .certificate:
                guard let record = item.certificate, !certificates.contains(where: { $0.id == record.id }) else {
                    throw TrashError.conflict
                }
                try trashStore.restorePayload(item.id, to: Self.certificateAttachmentsURL.appendingPathComponent(record.id, isDirectory: true))
                certificates.append(record)
            case .funding:
                guard let record = item.funding, !fundingRecords.contains(where: { $0.id == record.id }) else {
                    throw TrashError.conflict
                }
                fundingRecords.append(record)
            case .workAttachment:
                guard let attachment = item.attachment, let parentID = item.parentID,
                      let index = existingWorks.firstIndex(where: { $0.id == parentID }) else { throw TrashError.missingParent }
                let destination = Self.attachmentsURL
                    .appendingPathComponent(parentID, isDirectory: true)
                    .appendingPathComponent(attachment.storedName)
                try trashStore.restorePayload(item.id, to: destination)
                existingWorks[index].attachments.append(attachment)
            case .certificateAttachment:
                guard let attachment = item.attachment, let parentID = item.parentID,
                      let index = certificates.firstIndex(where: { $0.id == parentID }) else { throw TrashError.missingParent }
                let destination = Self.certificateAttachmentsURL
                    .appendingPathComponent(parentID, isDirectory: true)
                    .appendingPathComponent(attachment.storedName)
                try trashStore.restorePayload(item.id, to: destination)
                certificates[index].attachments.append(attachment)
            }
            trashItems.removeAll { $0.id == item.id }
            trashStore.removePayloadDirectory(item.id)
            if lastDeletedTrashID == item.id { lastDeletedTrashID = nil }
            deletionMessage = AppLocalization.format("已恢复“%@”", item.title)
            save()
        } catch {
            lastError = AppLocalization.format("无法恢复“%@”：%@", item.title, error.localizedDescription)
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
