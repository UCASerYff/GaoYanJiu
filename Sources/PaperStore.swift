import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import WebKit

// MARK: - PaperStore：门面与在投/门户/成果/项目/证书/资金的核心状态
//
// 拆分后的职责边界：
// - 持久化（路径解析、library.json 原子读写、损坏隔离、高版本拒绝、迁移链调度）
//   → LibraryRepository（默认 DiskLibraryRepository，可注入替身）
// - 研究城全部规则（金币/券/抽奖/地皮/摆放/旋转/地形）→ RewardCityStore
// - 回收站状态与 TrashStorage 文件操作 → TrashStore（跨集合编排在本文件的扩展里）
// - 资料库文件夹/文档与全文索引 → DocumentLibraryStore
// - 每日备份、便携备份导出/恢复 → BackupService
// 对视图层暴露的 @Published 属性与方法签名全部保留：子对象持有的状态经
// 计算属性转发，objectWillChange 级联上行，行为与 V4.4 逐字等价。

@MainActor
final class PaperStore: ObservableObject {
    @Published var papers: [PaperRecord] = []
    @Published var portals: [PortalAccount] = []
    @Published var existingWorks: [ExistingWork] = []
    @Published var projects: [ResearchProject] = []
    @Published var certificates: [CertificateRecord] = []
    @Published var fundingRecords: [FundingRecord] = []
    @Published var isRefreshing = false
    @Published var refreshMessage = ""
    @Published var lastError: String?
    @Published var backupMessage = ""
    /// 资料库加载失败（文件损坏或来自更新版本）时为 true；期间禁止一切写盘，避免用空库覆盖原始数据。
    @Published private(set) var libraryLoadFailed = false
    /// 被隔离的损坏资料库文件名（位于 Application Support 目录内），供 UI 展示；未隔离时为 nil。
    @Published private(set) var quarantinedLibraryFileName: String?
    /// 连续保存失败时升级的告警文案；保存成功后重置为 nil。
    @Published var persistenceAlert: String?
    /// 启动一致性扫描结果（缺失附件/孤儿文件的数量说明，中英双语）；无问题或扫描未结束时为 nil。只报告，不自动删除。
    @Published private(set) var consistencyReport: String?

    // 子对象：状态归属者。对外的同名属性经各文件中的转发扩展暴露。
    let repository: LibraryRepository
    let rewardStore: RewardCityStore
    let trashStore: TrashStore
    let documentLibrary: DocumentLibraryStore
    let backupService: BackupService

    private var refreshCoordinator: PortalRefreshCoordinator?
    private var consecutiveSaveFailures = 0
    private var cancellables: Set<AnyCancellable> = []

    init(repository: LibraryRepository = DiskLibraryRepository()) {
        self.repository = repository
        rewardStore = RewardCityStore()
        trashStore = TrashStore()
        documentLibrary = DocumentLibraryStore()
        backupService = BackupService()

        // 子对象 → 门面的单向回调：落盘与错误提示统一上行。
        rewardStore.persist = { [weak self] in self?.save() }
        rewardStore.errorHandler = { [weak self] in self?.lastError = $0 }
        trashStore.persist = { [weak self] in self?.save() }
        trashStore.errorHandler = { [weak self] in self?.lastError = $0 }
        documentLibrary.persist = { [weak self] in self?.save() }
        documentLibrary.errorHandler = { [weak self] in self?.lastError = $0 }
        backupService.persist = { [weak self] in self?.save() }
        backupService.reload = { [weak self] in self?.load() }
        backupService.messageHandler = { [weak self] in self?.backupMessage = $0 }
        backupService.errorHandler = { [weak self] in self?.lastError = $0 }
        backupService.libraryLoadFailedProvider = { [weak self] in self?.libraryLoadFailed ?? false }

        // objectWillChange 级联转发：子对象状态变化视同 PaperStore 变化，
        // 视图层只观察门面即可获得与原单类一致的刷新行为。
        rewardStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        trashStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        documentLibrary.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        load()
        if !libraryLoadFailed { exportWidgetSnapshot() }
        applyTestingCoinGrantIfRequested()
        purgeExpiredTrash()
        // 每日自动备份挪到启动完成后后台触发，不阻塞首屏（BackupService 内部逻辑不变）。
        Task { [weak self] in self?.createDailyAutomaticBackupIfNeeded() }
        scheduleConsistencyScanIfNeeded()
        indexUnindexedDocumentsIfNeeded()
    }

    var visiblePapers: [PaperRecord] {
        papers.filter { !$0.hidden }
    }

    /// 3.36：「在投」口径拆分——终态（接受/拒稿/撤稿等）不算在投。
    var inReviewPapers: [PaperRecord] {
        visiblePapers.filter { !SubmissionStatusClassifier.isTerminal($0.status) }
    }
    /// 已接受子集（终态里的 accept 类；publish 类已发表也算接受后的结果）。
    var acceptedPapers: [PaperRecord] {
        visiblePapers.filter { paper in
            let value = paper.status.lowercased()
            return ["accept", "publish", "已接受", "接收", "录用", "已发表"].contains { value.contains($0) }
        }
    }
    /// 需要跟进优先：有状态更新的未读稿件最前，其次仍在投，终态沉底；同档内保持原顺序。
    var followUpSortedPapers: [PaperRecord] {
        visiblePapers.enumerated().sorted { lhs, rhs in
            func rank(_ p: PaperRecord) -> Int {
                if p.changed { return 0 }
                return SubmissionStatusClassifier.isTerminal(p.status) ? 2 : 1
            }
            let l = rank(lhs.element), r = rank(rhs.element)
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }

    var changedCount: Int {
        visiblePapers.filter(\.changed).count
    }

    var lastChecked: Date? {
        papers.map(\.checkedAt).max()
    }

    func papers(matching filter: LibraryFilter, search: String) -> [PaperRecord] {
        let base: [PaperRecord]
        switch filter {
        case .all:
            base = papers.filter { !$0.hidden }
        case .existing:
            base = []
        case .projects:
            base = []
        case .experimentData, .summaryReports, .importantLiterature:
            base = []
        case .certificates:
            base = []
        case .funding:
            base = []
        case .rewardCity:
            base = []
        case .changed:
            base = papers.filter { !$0.hidden && $0.changed }
        case .hidden:
            base = papers.filter(\.hidden)
        }

        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return orderedPapers(base) }
        return orderedPapers(base.filter {
            [$0.title, $0.journal, $0.status, $0.manuscriptID, $0.site]
                .contains { $0.lowercased().contains(needle) }
        })
    }

    func existingWorks(matching search: String) -> [ExistingWork] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = needle.isEmpty ? existingWorks : existingWorks.filter {
            let metricText = $0.journalMetrics?.items
                .flatMap { [$0.label, $0.value] }
                .joined(separator: " ") ?? ""
            return [$0.title, $0.venue, $0.authors, $0.identifier, $0.type.title,
                    $0.patentType?.title ?? "", $0.authorPosition?.title ?? "",
                    $0.journalISSN ?? "", metricText]
                .contains { $0.lowercased().contains(needle) }
        }
        return orderedExistingWorks(base)
    }

    func projects(matching search: String) -> [ResearchProject] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = needle.isEmpty ? projects : projects.filter { project in
            let stepText = project.steps
                .flatMap { [$0.title, $0.details] }
                .joined(separator: " ")
            return [project.title, project.content, stepText]
                .contains { $0.lowercased().contains(needle) }
        }
        return orderedProjects(base)
    }

    func certificates(matching search: String) -> [CertificateRecord] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = needle.isEmpty ? certificates : certificates.filter { record in
            [record.name, record.tags.joined(separator: " "), record.attachments.map(\.originalName).joined(separator: " ")]
                .contains { $0.lowercased().contains(needle) }
        }
        return base.sorted {
            if $0.eventDate != $1.eventDate { return $0.eventDate > $1.eventDate }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func fundingRecords(matching search: String) -> [FundingRecord] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = needle.isEmpty ? fundingRecords : fundingRecords.filter { record in
            [record.name, record.receivingAccount, String(record.year),
             record.months.map(String.init).joined(separator: " ")]
                .contains { $0.lowercased().contains(needle) }
        }
        return base.sorted {
            if $0.year != $1.year { return $0.year > $1.year }
            if $0.name != $1.name { return $0.name.localizedCompare($1.name) == .orderedAscending }
            return $0.updatedAt > $1.updatedAt
        }
    }

    @discardableResult
    func saveManualSubmission(
        existingID: String?,
        title: String,
        venue: String,
        manuscriptID: String,
        status: String,
        statusSince: Date,
        portalURL: String,
        notes: String
    ) -> String {
        let cleanTitle = clean(title)
        let cleanVenue = clean(venue)
        let cleanManuscriptID = clean(manuscriptID)
        let cleanStatus = clean(status)
        let cleanURL = clean(portalURL)
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        if let existingID, let index = papers.firstIndex(where: { $0.id == existingID }) {
            let oldStatus = papers[index].status
            if oldStatus != cleanStatus {
                papers[index].previousStatus = oldStatus
                papers[index].history.append(StatusEvent(status: cleanStatus, checkedAt: statusSince))
            }
            papers[index].title = cleanTitle
            papers[index].journal = cleanVenue.isEmpty ? "未填写期刊或会议" : cleanVenue
            papers[index].manuscriptID = cleanManuscriptID.isEmpty ? "未填写" : cleanManuscriptID
            papers[index].status = cleanStatus
            papers[index].statusSince = statusSince
            papers[index].statusSinceSource = "手动设置"
            papers[index].checkedAt = now
            papers[index].url = cleanURL
            papers[index].submissionHistory = cleanNotes.isEmpty ? nil : cleanNotes
            papers[index].changed = false
            papers = orderedPapers(papers)
            save()
            return existingID
        }

        let id = "manual:\(UUID().uuidString)"
        papers.append(PaperRecord(
            key: id,
            sourceID: "manual",
            site: "手动录入",
            url: cleanURL,
            manuscriptID: cleanManuscriptID.isEmpty ? "未填写" : cleanManuscriptID,
            title: cleanTitle,
            journal: cleanVenue.isEmpty ? "未填写期刊或会议" : cleanVenue,
            status: cleanStatus,
            checkedAt: now,
            statusSince: statusSince,
            statusSinceSource: "手动设置",
            previousStatus: nil,
            changed: false,
            hidden: false,
            history: [StatusEvent(status: cleanStatus, checkedAt: statusSince)],
            submissionHistory: cleanNotes.isEmpty ? nil : cleanNotes,
            sortOrder: nextPaperSortOrder()
        ))
        normalizePaperOrdering(from: orderedPapers(papers))
        save()
        return id
    }

    @discardableResult
    func saveExistingWork(
        existingID: String?,
        title: String,
        type: ExistingWorkType,
        venue: String,
        authors: String,
        completedAt: Date,
        identifier: String,
        url: String,
        notes: String,
        patentType: PatentType?,
        authorPosition: AuthorPosition?,
        journalISSN: String?,
        journalMetrics: JournalMetricsSnapshot?
    ) -> String {
        let now = Date()
        if let existingID, let index = existingWorks.firstIndex(where: { $0.id == existingID }) {
            existingWorks[index].title = clean(title)
            existingWorks[index].type = type
            existingWorks[index].venue = clean(venue)
            existingWorks[index].authors = clean(authors)
            existingWorks[index].completedAt = completedAt
            existingWorks[index].identifier = clean(identifier)
            existingWorks[index].url = clean(url)
            existingWorks[index].notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            existingWorks[index].patentType = type == .patent ? patentType : nil
            existingWorks[index].authorPosition = authorPosition
            existingWorks[index].journalISSN = type == .journalArticle ? clean(journalISSN ?? "") : nil
            existingWorks[index].journalMetrics = type == .journalArticle ? journalMetrics : nil
            existingWorks[index].updatedAt = now
            save()
            return existingID
        }

        let id = UUID().uuidString
        existingWorks.append(ExistingWork(
            id: id,
            title: clean(title),
            type: type,
            venue: clean(venue),
            authors: clean(authors),
            completedAt: completedAt,
            identifier: clean(identifier),
            url: clean(url),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: [],
            createdAt: now,
            updatedAt: now,
            patentType: type == .patent ? patentType : nil,
            journalISSN: type == .journalArticle ? clean(journalISSN ?? "") : nil,
            journalMetrics: type == .journalArticle ? journalMetrics : nil,
            authorPosition: authorPosition,
            sortOrder: nextExistingWorkSortOrder()
        ))
        normalizeExistingWorkOrdering(from: orderedExistingWorks(existingWorks))
        rewardStore.grantRewardForWorkIfNeeded(id: id, type: type)
        save()
        return id
    }

    @discardableResult
    func saveProject(
        existingID: String?,
        title: String,
        content: String,
        steps: [ProjectStep]
    ) -> String {
        let now = Date()
        let normalizedSteps = steps.map { step in
            ProjectStep(
                id: step.id,
                title: clean(step.title),
                details: step.details.trimmingCharacters(in: .whitespacesAndNewlines),
                startDate: step.startDate,
                endDate: max(step.startDate, step.endDate),
                isCompleted: step.isCompleted
            )
        }

        if let existingID, let index = projects.firstIndex(where: { $0.id == existingID }) {
            projects[index].title = clean(title)
            projects[index].content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            projects[index].steps = normalizedSteps
            projects[index].updatedAt = now
            save()
            return existingID
        }

        let id = UUID().uuidString
        projects.append(ResearchProject(
            id: id,
            title: clean(title),
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            steps: normalizedSteps,
            createdAt: now,
            updatedAt: now,
            sortOrder: nextProjectSortOrder()
        ))
        normalizeProjectOrdering(from: orderedProjects(projects))
        save()
        return id
    }

    func setProjectStepCompleted(projectID: String, stepID: String, isCompleted: Bool) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
              let stepIndex = projects[projectIndex].steps.firstIndex(where: { $0.id == stepID }) else { return }
        projects[projectIndex].steps[stepIndex].isCompleted = isCompleted
        projects[projectIndex].updatedAt = Date()
        save()
    }

    func deleteProject(_ project: ResearchProject) {
        moveProjectToTrash(project)
    }

    @discardableResult
    func saveCertificate(
        existingID: String?,
        name: String,
        eventDate: Date,
        tags: [String]
    ) -> String {
        let now = Date()
        var normalizedTags: [String] = []
        for tag in tags {
            let value = clean(tag)
            guard !value.isEmpty,
                  !normalizedTags.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { continue }
            normalizedTags.append(value)
        }

        if let existingID, let index = certificates.firstIndex(where: { $0.id == existingID }) {
            certificates[index].name = clean(name)
            certificates[index].eventDate = eventDate
            certificates[index].tags = normalizedTags
            certificates[index].updatedAt = now
            save()
            return existingID
        }

        let id = UUID().uuidString
        certificates.append(CertificateRecord(
            id: id,
            name: clean(name),
            eventDate: eventDate,
            tags: normalizedTags,
            attachments: [],
            createdAt: now,
            updatedAt: now
        ))
        rewardStore.grantRewardForCertificateIfNeeded(id: id)
        save()
        return id
    }

    func addCertificateAttachments(to recordID: String) {
        guard let index = certificates.firstIndex(where: { $0.id == recordID }) else { return }
        let panel = NSOpenPanel()
        panel.title = "选择证书 PDF 或图片"
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }

        do {
            let destinationDirectory = Self.certificateAttachmentsURL.appendingPathComponent(recordID, isDirectory: true)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            var additions: [WorkAttachment] = []
            for sourceURL in panel.urls {
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
                let ext = sourceURL.pathExtension.lowercased()
                let storedName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
                let destinationURL = destinationDirectory.appendingPathComponent(storedName)
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                additions.append(WorkAttachment(
                    id: UUID().uuidString,
                    originalName: sourceURL.lastPathComponent,
                    storedName: storedName,
                    kind: ext == "pdf" ? "pdf" : "image",
                    addedAt: Date()
                ))
            }
            certificates[index].attachments.append(contentsOf: additions)
            certificates[index].updatedAt = Date()
            save()
        } catch {
            lastError = "证书附件导入失败：\(error.localizedDescription)"
        }
    }

    func openCertificateAttachment(_ attachment: WorkAttachment, for record: CertificateRecord) {
        let url = certificateAttachmentURL(attachment, for: record)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "找不到附件“\(attachment.originalName)”。"
            return
        }
        NSWorkspace.shared.open(url)
    }

    func deleteCertificateAttachment(_ attachment: WorkAttachment, from recordID: String) {
        moveCertificateAttachmentToTrash(attachment, recordID: recordID)
    }

    func deleteCertificate(_ record: CertificateRecord) {
        moveCertificateToTrash(record)
    }

    func certificateAttachmentURL(_ attachment: WorkAttachment, for record: CertificateRecord) -> URL {
        Self.certificateAttachmentsURL
            .appendingPathComponent(record.id, isDirectory: true)
            .appendingPathComponent(attachment.storedName)
    }

    @discardableResult
    func saveFundingRecord(
        existingID: String?,
        name: String,
        amount: Double,
        year: Int,
        months: [Int],
        receivingAccount: String
    ) -> String {
        let now = Date()
        let normalizedMonths = Array(Set(months.filter { (1...12).contains($0) })).sorted()

        if let existingID, let index = fundingRecords.firstIndex(where: { $0.id == existingID }) {
            fundingRecords[index].name = clean(name)
            fundingRecords[index].amount = max(0, amount)
            fundingRecords[index].year = year
            fundingRecords[index].months = normalizedMonths
            fundingRecords[index].receivingAccount = clean(receivingAccount)
            fundingRecords[index].updatedAt = now
            save()
            return existingID
        }

        let id = UUID().uuidString
        fundingRecords.append(FundingRecord(
            id: id,
            name: clean(name),
            amount: max(0, amount),
            year: year,
            months: normalizedMonths,
            receivingAccount: clean(receivingAccount),
            createdAt: now,
            updatedAt: now
        ))
        save()
        return id
    }

    func deleteFundingRecord(_ record: FundingRecord) {
        moveFundingToTrash(record)
    }

    func addAttachments(to workID: String) {
        guard let index = existingWorks.firstIndex(where: { $0.id == workID }) else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 PDF 或图片"
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }

        do {
            let destinationDirectory = Self.attachmentsURL.appendingPathComponent(workID, isDirectory: true)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            var additions: [WorkAttachment] = []
            for sourceURL in panel.urls {
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
                let ext = sourceURL.pathExtension.lowercased()
                let storedName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
                let destinationURL = destinationDirectory.appendingPathComponent(storedName)
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                additions.append(WorkAttachment(
                    id: UUID().uuidString,
                    originalName: sourceURL.lastPathComponent,
                    storedName: storedName,
                    kind: ext == "pdf" ? "pdf" : "image",
                    addedAt: Date()
                ))
            }
            existingWorks[index].attachments.append(contentsOf: additions)
            existingWorks[index].updatedAt = Date()
            save()
        } catch {
            lastError = "附件导入失败：\(error.localizedDescription)"
        }
    }

    func openAttachment(_ attachment: WorkAttachment, for work: ExistingWork) {
        let url = attachmentURL(attachment, for: work)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "找不到附件“\(attachment.originalName)”。"
            return
        }
        NSWorkspace.shared.open(url)
    }

    func deleteAttachment(_ attachment: WorkAttachment, from workID: String) {
        moveWorkAttachmentToTrash(attachment, workID: workID)
    }

    func deleteExistingWork(_ work: ExistingWork) {
        moveWorkToTrash(work)
    }

    func attachmentURL(_ attachment: WorkAttachment, for work: ExistingWork) -> URL {
        Self.attachmentsURL
            .appendingPathComponent(work.id, isDirectory: true)
            .appendingPathComponent(attachment.storedName)
    }

    @discardableResult
    func merge(
        _ result: ExtractionResult,
        publisher: PublisherDefinition,
        existingPortalID: String? = nil
    ) -> ImportOutcome {
        let checkedAt = parseDate(result.checkedAt) ?? Date()
        let validPapers = result.papers.filter { isPlausibleExtraction($0, publisher: publisher) }
        let identity = Self.portalIdentity(for: result.url, kind: publisher.kind)
        let portalIndex: Int?
        if let existingPortalID {
            portalIndex = portals.firstIndex(where: { $0.id == existingPortalID })
        } else {
            portalIndex = portals.firstIndex(where: {
                $0.publisherID == publisher.id && $0.identity == identity
            })
        }

        let portal: PortalAccount
        if let portalIndex {
            portals[portalIndex].url = result.url
            portals[portalIndex].lastChecked = checkedAt
            portals[portalIndex].lastError = nil
            portal = portals[portalIndex]
        } else {
            let host = URL(string: result.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? publisher.name
            let newPortal = PortalAccount(
                id: UUID().uuidString,
                publisherID: publisher.id,
                publisherName: publisher.name,
                kind: publisher.kind,
                name: publisher.kind == "custom" || publisher.id.hasPrefix("custom-")
                    ? publisher.name
                    : "\(publisher.name) · \(host)",
                url: result.url,
                identity: identity,
                createdAt: Date(),
                lastChecked: checkedAt,
                lastError: nil
            )
            portals.append(newPortal)
            portal = newPortal
        }

        var changes = 0
        var importedCount = 0
        for extracted in validPapers {
            let manuscriptID = clean(extracted.id).isEmpty ? clean(extracted.title) : clean(extracted.id)
            guard !manuscriptID.isEmpty, !clean(extracted.status).isEmpty else { continue }
            importedCount += 1
            let key = "\(portal.id):\(manuscriptID)"
            let titleMatches = papers.indices.filter {
                papers[$0].sourceID == portal.id && clean(papers[$0].title).lowercased() == clean(extracted.title).lowercased()
                    && (papers[$0].manuscriptID.hasPrefix("pending:") || manuscriptID.hasPrefix("pending:"))
            }
            let matchingIndex = papers.firstIndex(where: { $0.key == key || ($0.sourceID == portal.id && $0.manuscriptID == manuscriptID) })
                ?? (titleMatches.count == 1 ? titleMatches.first : nil)
            let status = clean(extracted.status)
            let reportedStatusSince = parseDate(extracted.statusSince)
            let statusSince = reportedStatusSince ?? checkedAt
            let journal = preferredJournal(
                incoming: extracted.journal,
                existing: matchingIndex.map { papers[$0].journal },
                resultURL: result.url,
                publisher: publisher
            )

            if let index = matchingIndex {
                if !manuscriptID.hasPrefix("pending:") {
                    papers[index].manuscriptID = manuscriptID
                }
                if papers[index].hidden { continue }
                let oldStatus = papers[index].status
                let didChange = oldStatus != status
                if didChange {
                    changes += 1
                    papers[index].previousStatus = oldStatus
                    // A newly detected status starts a new duration period. Publisher pages
                    // occasionally expose the submission date as a generic "status date";
                    // carrying that value forward made the current-status chart look as if it
                    // had never reset. Use the actual detection time for every transition.
                    papers[index].history.append(StatusEvent(status: status, checkedAt: checkedAt))
                        papers[index].changed = true
                    papers[index].statusSince = checkedAt
                    papers[index].statusSinceSource = "检测到状态变更"
                }
                papers[index].status = status
                papers[index].title = clean(extracted.title).isEmpty ? papers[index].title : clean(extracted.title)
                if !journal.isEmpty { papers[index].journal = journal }
                papers[index].site = publisher.name
                papers[index].url = result.url
                papers[index].checkedAt = checkedAt
                if !didChange, let source = extracted.statusSinceSource {
                    papers[index].statusSinceSource = source
                }
                if let history = extracted.submissionHistory, !clean(history).isEmpty {
                    papers[index].submissionHistory = clean(history)
                }
            } else {
                papers.append(PaperRecord(
                    key: key,
                    sourceID: portal.id,
                    site: publisher.name,
                    url: result.url,
                    manuscriptID: manuscriptID,
                    title: clean(extracted.title).isEmpty ? "未命名论文" : clean(extracted.title),
                    journal: journal.isEmpty ? "未识别期刊" : journal,
                    status: status,
                    checkedAt: checkedAt,
                    statusSince: statusSince,
                    statusSinceSource: extracted.statusSinceSource ?? "首次由系统发现",
                    previousStatus: nil,
                    changed: false,
                    hidden: false,
                    history: [StatusEvent(status: status, checkedAt: statusSince)],
                    submissionHistory: extracted.submissionHistory.map(clean),
                    sortOrder: nextPaperSortOrder()
                ))
            }
        }

        normalizePaperOrdering(from: orderedPapers(papers))
        save()
        return ImportOutcome(importedCount: importedCount, changedCount: changes, portal: portal)
    }

    func movePaper(sourceID: String, before targetID: String, persist: Bool = true) {
        guard sourceID != targetID else { return }
        var ordered = orderedPapers(papers)
        guard
            let sourceIndex = ordered.firstIndex(where: { $0.id == sourceID }),
            let targetIndex = ordered.firstIndex(where: { $0.id == targetID })
        else { return }

        let moving = ordered.remove(at: sourceIndex)
        ordered.insert(moving, at: min(targetIndex, ordered.count))
        normalizePaperOrdering(from: ordered)
        // persist=false 时只改内存与排序归一化；拖动结束时由调用方统一 save()。
        if persist { save() }
    }

    func moveExistingWork(sourceID: String, before targetID: String, persist: Bool = true) {
        guard sourceID != targetID else { return }
        var ordered = orderedExistingWorks(existingWorks)
        guard
            let sourceIndex = ordered.firstIndex(where: { $0.id == sourceID }),
            let targetIndex = ordered.firstIndex(where: { $0.id == targetID })
        else { return }

        let moving = ordered.remove(at: sourceIndex)
        ordered.insert(moving, at: min(targetIndex, ordered.count))
        normalizeExistingWorkOrdering(from: ordered)
        if persist { save() }
    }

    func moveProject(sourceID: String, before targetID: String, persist: Bool = true) {
        guard sourceID != targetID else { return }
        var ordered = orderedProjects(projects)
        guard
            let sourceIndex = ordered.firstIndex(where: { $0.id == sourceID }),
            let targetIndex = ordered.firstIndex(where: { $0.id == targetID })
        else { return }

        let moving = ordered.remove(at: sourceIndex)
        ordered.insert(moving, at: min(targetIndex, ordered.count))
        normalizeProjectOrdering(from: ordered)
        // persist=false 时只改内存与排序归一化；拖动结束时由调用方统一 save()。
        if persist { save() }
    }

    func markRead(_ paper: PaperRecord) {
        updatePaper(paper.id) { $0.changed = false }
    }

    func setArchived(_ paper: PaperRecord, archived: Bool) {
        updatePaper(paper.id) {
            $0.hidden = archived
            if archived { $0.changed = false }
        }
    }

    func delete(_ paper: PaperRecord) {
        movePaperToTrash(paper)
    }

    func removePortal(_ portal: PortalAccount) {
        removePortal(portal, cleanupWebsiteData: false)
    }

    /// 移除门户。cleanupWebsiteData 为 true 时顺带清理：
    /// 1) 该门户域名在 WKWebsiteDataStore 默认存储中的 Cookie/缓存等网站数据（后台异步，不阻塞移除）；
    /// 2) 该门户在钥匙串中保存的登录凭据。
    func removePortal(_ portal: PortalAccount, cleanupWebsiteData: Bool) {
        if cleanupWebsiteData {
            PortalCredentialStore.delete(key: PortalCredentialStore.key(for: portal.url, publisher: portal.publisher))
            let host = URL(string: portal.url)?.host?
                .lowercased()
                .replacingOccurrences(of: "www.", with: "") ?? ""
            if !host.isEmpty {
                Task { await Self.removeWebsiteData(forHost: host) }
            }
        }
        portals.removeAll { $0.id == portal.id }
        save()
    }

    /// 按域名匹配删除默认 WKWebsiteDataStore 中的全部网站数据（Cookie、缓存等）。
    /// displayName 可能是子域或父域，双向后缀匹配；与门户移除解耦，失败仅记日志。
    nonisolated static func removeWebsiteData(forHost host: String) async {
        let dataStore = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: types)
        let matches = records.filter { record in
            let name = record.displayName.lowercased().replacingOccurrences(of: "www.", with: "")
            return name == host || name.hasSuffix(".\(host)") || host.hasSuffix(".\(name)")
        }
        guard !matches.isEmpty else { return }
        await dataStore.removeData(ofTypes: types, for: matches)
        NSLog("Removed %d website data record(s) for portal host %@", matches.count, host)
    }

    func refreshAll() {
        guard !isRefreshing, !portals.isEmpty else { return }
        isRefreshing = true
        lastError = nil
        refreshMessage = "正在连接 1 / \(portals.count)"

        let coordinator = PortalRefreshCoordinator()
        refreshCoordinator = coordinator
        coordinator.refresh(
            portals: portals,
            progress: { [weak self] completed, total, portal in
                self?.refreshMessage = "正在检查 \(portal.publisherName)（\(completed + 1) / \(total)）"
            },
            result: { [weak self] portal, extraction in
                guard let self, self.portals.contains(where: { $0.id == portal.id }) else { return }
                _ = self.merge(extraction, publisher: portal.publisher, existingPortalID: portal.id)
            },
            failure: { [weak self] portal, message in
                guard let self else { return }
                if let index = self.portals.firstIndex(where: { $0.id == portal.id }) {
                    self.portals[index].lastError = message
                }
            },
            completion: { [weak self] failures in
                guard let self else { return }
                self.isRefreshing = false
                self.refreshMessage = failures == 0 ? "刷新完成" : "刷新完成，\(failures) 个门户需要重新登录"
                if failures > 0 {
                    self.lastError = "部分出版商登录状态已失效，请从“已连接门户”重新打开并登录。"
                }
                self.save()
                self.refreshCoordinator = nil
            }
        )
    }

    // MARK: - 加载与保存（委托 LibraryRepository）

    func load() {
        libraryLoadFailed = false
        quarantinedLibraryFileName = nil
        consecutiveSaveFailures = 0
        persistenceAlert = nil
        switch repository.loadLibrary(migratingWith: Self.applyLibraryMigration) {
        case let .loaded(library, originalVersion, migratedLegacyDirectory, migrationBackupError):
            if let migrationBackupError {
                lastError = "旧版数据可以读取，但升级前安全备份创建失败：\(migrationBackupError.localizedDescription)"
            }
            papers = legacySortedPapers(library.papers)
            portals = library.portals
            existingWorks = legacySortedExistingWorks(library.existingWorks)
            projects = library.projects
            certificates = library.certificates
            fundingRecords = library.fundingRecords
            documentFolders = library.documentFolders
            managedDocuments = library.managedDocuments
            trashItems = library.trashItems
            rewardCity = library.rewardCity
            normalizePaperOrdering(from: orderedPapers(papers))
            normalizeExistingWorkOrdering(from: orderedExistingWorks(existingWorks))
            normalizeProjectOrdering(from: orderedProjects(projects))
            normalizeDocumentFolderOrdering()
            normalizeManagedDocumentOrdering()

            if migratedLegacyDirectory || originalVersion < Self.currentLibraryVersion {
                save()
                refreshMessage = migratedLegacyDirectory
                    ? "已自动迁移旧版资料库及附件"
                    : "\(LibrarySchema.releaseName(forLibraryVersion: originalVersion)) 数据及附件已迁移到 \(Self.marketingVersion)"
            }
        case .empty:
            papers = []
            portals = []
            existingWorks = []
            projects = []
            certificates = []
            fundingRecords = []
            documentFolders = []
            managedDocuments = []
            trashItems = []
            rewardCity = RewardCityState()
        case .futureVersion(let version):
            // 资料库来自更新版本：不隔离（文件本身完好，升级后仍须原位可读），
            // 只阻断写盘并提示升级。
            libraryLoadFailed = true
            lastError = AppLocalization.language == .english
                ? "The library was created by a newer version of the app (data version \(version)) and cannot be read by this version. Please update the app; your data on disk has not been modified."
                : "资料库由更新版本的搞研究创建（数据版本 \(version)），当前版本无法读取。请升级 App 后再打开；磁盘上的数据未被改动。"
        case .corrupted(let quarantinedFileName, let error):
            quarantinedLibraryFileName = quarantinedFileName
            libraryLoadFailed = true
            let english = AppLocalization.language == .english
            var detail = english
                ? "The local library could not be read: \(error.localizedDescription)."
                : "本地资料库读取失败：\(error.localizedDescription)。"
            if let quarantinedFileName {
                detail += english
                    ? " The unreadable file has been set aside as “\(quarantinedFileName)” and will not be overwritten."
                    : "原文件已隔离为“\(quarantinedFileName)”，不会被覆盖。"
            }
            detail += english
                ? " All saving is paused to protect your data; you can restore a daily automatic backup via the “Backup & Restore” menu."
                : "为保护数据已暂停所有写入，可通过工具栏「备份与恢复」从每日自动备份恢复。"
            lastError = detail
        }
    }

    /// 迁移链步骤分发：阈值序列由 LibraryRepository 调度，各步骤本体分别归属
    /// 论文（本类）与研究城（RewardCityStore 静态函数）。
    private nonisolated static func applyLibraryMigration(_ library: inout PersistedLibrary, _ threshold: Int) {
        switch threshold {
        case 14, 25:
            migrateLegacyJournalHints(&library)
        case 18:
            migrateLegacyStatusTiming(&library)
        case 19:
            // V2.6 changes presentation and portal extraction rules only. Running
            // the normalizers during migration keeps legacy custom ordering intact
            // while still producing a new, explicitly backed-up schema revision.
            library.papers = normalizedPaperOrdering(sortedPapers(library.papers))
            library.existingWorks = normalizedExistingWorkOrdering(sortedExistingWorks(library.existingWorks))
            library.documentFolders = DocumentLibraryStore.normalizedFolderOrdering(library.documentFolders)
        case 20:
            RewardCityStore.migrateToV30(
                state: &library.rewardCity,
                works: library.existingWorks.map { (id: $0.id, type: $0.type) },
                certificateIDs: library.certificates.map(\.id)
            )
        case 21, 22, 23, 24:
            // V3.2/V3.3/V3.4 均只改变渲染管线，重复跑 V3.1 的锚点迁移作为防御。
            RewardCityStore.migrateToV31(state: &library.rewardCity)
        case 29:
            RewardCityStore.migrateToV39(state: &library.rewardCity)
        case 32:
            // V4.6：项目与资料库文件新增手动排序字段。按旧默认顺序
            // （项目按 updatedAt 降序、文件按上传时间降序）补连续 sortOrder 初值。
            library.projects = normalizedProjectOrdering(sortedProjects(library.projects))
            library.managedDocuments = DocumentLibraryStore.normalizedDocumentOrdering(library.managedDocuments)
        default:
            break
        }
    }

    private nonisolated static func migrateLegacyJournalHints(_ library: inout PersistedLibrary) {
        for index in library.papers.indices where isGenericPortalJournal(library.papers[index].journal) {
            if let journal = editorialManagerJournalHint(for: library.papers[index].url) {
                library.papers[index].journal = journal
            }
        }
    }

    private nonisolated static func migrateLegacyStatusTiming(_ library: inout PersistedLibrary) {
        for index in library.papers.indices {
            if let journal = editorialManagerJournalHint(for: library.papers[index].url) {
                library.papers[index].journal = journal
            }

            let paper = library.papers[index]
            let source = paper.statusSinceSource.lowercased()
            let isImported = paper.sourceID != "manual" && paper.site != "手动添加"
            let hasAmbiguousLegacyTiming = paper.previousStatus != nil
                && !source.contains("手动")
                && !source.contains("检测到状态变更")
                && paper.checkedAt.timeIntervalSince(paper.statusSince) > 60
            guard isImported, hasAmbiguousLegacyTiming else { continue }

            // Older Wiley imports could attach a workflow start date to a new
            // status. The refresh time is the reliable local transition point.
            library.papers[index].statusSince = paper.checkedAt
            library.papers[index].statusSinceSource = "V2.5 修复：按状态变更检测时间重新计时"
            if let historyIndex = library.papers[index].history.lastIndex(where: { $0.status == paper.status }) {
                library.papers[index].history[historyIndex] = StatusEvent(status: paper.status, checkedAt: paper.checkedAt)
            } else {
                library.papers[index].history.append(StatusEvent(status: paper.status, checkedAt: paper.checkedAt))
            }
        }
    }

    private func applyTestingCoinGrantIfRequested() {
        guard let amount = rewardStore.applyTestingCoinGrantIfRequested() else { return }
        save()
        backupMessage = AppLocalization.format("已为本机测试资料发放 %d 金币", Int(amount))
    }

    func save() {
        // 资料库未能成功加载时禁止写盘，避免用内存中的空库原子覆盖磁盘上的原始数据。
        guard !libraryLoadFailed else {
            NSLog("Refusing to save because the library failed to load; on-disk data is left untouched.")
            return
        }
        do {
            try repository.saveLibrary(PersistedLibrary(
                papers: papers,
                portals: portals,
                existingWorks: existingWorks,
                projects: projects,
                certificates: certificates,
                fundingRecords: fundingRecords,
                documentFolders: documentFolders,
                managedDocuments: managedDocuments,
                trashItems: trashItems,
                rewardCity: rewardCity
            ))
            exportWidgetSnapshot()
            consecutiveSaveFailures = 0
            persistenceAlert = nil
        } catch {
            lastError = "本地资料库保存失败：\(error.localizedDescription)"
            consecutiveSaveFailures += 1
            // 第 2 次连续失败起升级为弹窗告警，避免单次抖动轰炸用户。
            if consecutiveSaveFailures >= 2 {
                persistenceAlert = AppLocalization.language == .english
                    ? "Saving the library failed repeatedly: \(error.localizedDescription)\n\nRecent changes may not have been written to disk. Check the free disk space and the permissions of ~/Library/Application Support/AcademicAchievementManager, and export a full backup via the “Backup & Restore” menu as soon as possible."
                    : "本地资料库连续保存失败：\(error.localizedDescription)\n\n最近的修改可能未写入磁盘。请检查磁盘剩余空间以及 ~/Library/Application Support/AcademicAchievementManager 的读写权限，并尽快通过「备份与恢复」菜单导出一份完整备份。"
            }
        }
    }

    // MARK: - 启动一致性扫描（只报告，不自动删除）

    /// load 完成后调度后台扫描：比对记录引用与磁盘附件，找缺失与孤儿文件。
    /// 资料库加载失败时不扫描——此时内存为空库，会把全部磁盘文件误报为孤儿。
    private func scheduleConsistencyScanIfNeeded() {
        guard !libraryLoadFailed else { return }
        let workRefs: [(recordID: String, storedNames: [String])] = existingWorks.map { work in
            (work.id, work.attachments.map { URL(fileURLWithPath: $0.storedName).lastPathComponent })
        }
        let certificateRefs: [(recordID: String, storedNames: [String])] = certificates.map { record in
            (record.id, record.attachments.map { URL(fileURLWithPath: $0.storedName).lastPathComponent })
        }
        // 文档库按 <kind>/<文件夹ID>/<storedName> 归组。
        var documentRefs: [String: [(recordID: String, storedNames: [String])]] = [:]
        for document in managedDocuments {
            guard let folder = documentLibrary.folders.first(where: { $0.id == document.folderID }) else { continue }
            let storedName = URL(fileURLWithPath: document.storedName).lastPathComponent
            documentRefs[folder.libraryKind.rawValue, default: []]
                .append((folder.id, [storedName]))
        }
        let english = AppLocalization.language == .english
        Task.detached(priority: .utility) { [weak self] in
            var missing: [String] = []
            var orphans: [String] = []
            Self.scanFlatAttachmentStore(
                root: LibraryPaths.attachments, refs: Self.mergedRefs(workRefs),
                label: "Attachments", missing: &missing, orphans: &orphans)
            Self.scanFlatAttachmentStore(
                root: LibraryPaths.certificateAttachments, refs: Self.mergedRefs(certificateRefs),
                label: "CertificateAttachments", missing: &missing, orphans: &orphans)
            for (kind, refs) in documentRefs {
                Self.scanFlatAttachmentStore(
                    root: LibraryPaths.managedDocuments.appendingPathComponent(kind, isDirectory: true),
                    refs: Self.mergedRefs(refs),
                    label: "ManagedDocuments/\(kind)", missing: &missing, orphans: &orphans)
            }
            let summary = Self.consistencySummary(missing: missing, orphans: orphans, english: english)
            await MainActor.run { [weak self] in
                self?.consistencyReport = summary
            }
        }
    }

    /// 同一记录可能有多条引用，按记录 ID 合并 storedName 列表。
    private nonisolated static func mergedRefs(
        _ refs: [(recordID: String, storedNames: [String])]
    ) -> [(recordID: String, storedNames: [String])] {
        var merged: [String: [String]] = [:]
        var order: [String] = []
        for ref in refs {
            if merged[ref.recordID] == nil { order.append(ref.recordID) }
            merged[ref.recordID, default: []].append(contentsOf: ref.storedNames)
        }
        return order.map { ($0, merged[$0] ?? []) }
    }

    /// 扫描一层 <记录ID>/<storedName> 结构的附件目录：记录引用但磁盘缺失 → missing；
    /// 磁盘存在但无记录引用 → orphans。隐藏文件（.DS_Store 等）跳过。
    private nonisolated static func scanFlatAttachmentStore(
        root: URL,
        refs: [(recordID: String, storedNames: [String])],
        label: String,
        missing: inout [String],
        orphans: inout [String]
    ) {
        let fileManager = FileManager.default
        var referenced: Set<String> = []
        for ref in refs {
            for name in ref.storedNames {
                referenced.insert("\(ref.recordID)/\(name)")
                let path = root.appendingPathComponent(ref.recordID).appendingPathComponent(name).path
                if !fileManager.fileExists(atPath: path) {
                    missing.append("\(label)/\(ref.recordID)/\(name)")
                }
            }
        }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        for entry in entries where !entry.hasPrefix(".") {
            let entryURL = root.appendingPathComponent(entry, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                orphans.append("\(label)/\(entry)")
                continue
            }
            guard let files = try? fileManager.contentsOfDirectory(atPath: entryURL.path) else { continue }
            for file in files where !file.hasPrefix(".") {
                if !referenced.contains("\(entry)/\(file)") {
                    orphans.append("\(label)/\(entry)/\(file)")
                }
            }
        }
    }

    /// 汇总扫描结果：无问题返回 nil；有问题返回中英双语数量说明并 NSLog 明细。不删除任何文件。
    private nonisolated static func consistencySummary(missing: [String], orphans: [String], english: Bool) -> String? {
        guard !missing.isEmpty || !orphans.isEmpty else { return nil }
        for line in missing { NSLog("Consistency scan: attachment referenced but missing on disk: %@", line) }
        for line in orphans { NSLog("Consistency scan: file on disk not referenced by any record: %@", line) }
        if english {
            return "Consistency scan found \(missing.count) attachment(s) referenced by records but missing on disk, and \(orphans.count) file(s) on disk not referenced by any record. Nothing was deleted; see the Console log for details."
        }
        return "一致性扫描发现 \(missing.count) 个记录引用的附件在磁盘上缺失、\(orphans.count) 个磁盘文件没有记录引用。未删除任何文件，明细见控制台日志。"
    }

    // MARK: - 内部工具

    private func updatePaper(_ id: String, change: (inout PaperRecord) -> Void) {
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        change(&papers[index])
        save()
    }

    private func legacySortedPapers(_ records: [PaperRecord]) -> [PaperRecord] {
        records.sorted {
            if $0.changed != $1.changed { return $0.changed && !$1.changed }
            return $0.checkedAt > $1.checkedAt
        }
    }

    private func legacySortedExistingWorks(_ records: [ExistingWork]) -> [ExistingWork] {
        records.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
            return $0.updatedAt > $1.updatedAt
        }
    }

    nonisolated static func sortedPapers(_ records: [PaperRecord]) -> [PaperRecord] {
        records.sorted { left, right in
            switch (left.sortOrder, right.sortOrder) {
            case let (leftOrder?, rightOrder?):
                if leftOrder != rightOrder { return leftOrder < rightOrder }
                return left.checkedAt > right.checkedAt
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                // 3.36：默认排序把需要跟进的排前面——状态有更新的最前，仍在投其次，终态（已接受/拒/撤）沉底。
                if left.changed != right.changed { return left.changed && !right.changed }
                let leftTerminal = SubmissionStatusClassifier.isTerminal(left.status)
                let rightTerminal = SubmissionStatusClassifier.isTerminal(right.status)
                if leftTerminal != rightTerminal { return !leftTerminal }
                return left.checkedAt > right.checkedAt
            }
        }
    }

    nonisolated static func sortedExistingWorks(_ records: [ExistingWork]) -> [ExistingWork] {
        records.sorted { left, right in
            switch (left.sortOrder, right.sortOrder) {
            case let (leftOrder?, rightOrder?):
                if leftOrder != rightOrder { return leftOrder < rightOrder }
                return left.updatedAt > right.updatedAt
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                if left.completedAt != right.completedAt { return left.completedAt > right.completedAt }
                return left.updatedAt > right.updatedAt
            }
        }
    }

    nonisolated static func normalizedPaperOrdering(_ ordered: [PaperRecord]) -> [PaperRecord] {
        ordered.enumerated().map { index, record in
            var record = record
            record.sortOrder = index
            return record
        }
    }

    nonisolated static func normalizedExistingWorkOrdering(_ ordered: [ExistingWork]) -> [ExistingWork] {
        ordered.enumerated().map { index, work in
            var work = work
            work.sortOrder = index
            return work
        }
    }

    nonisolated static func sortedProjects(_ records: [ResearchProject]) -> [ResearchProject] {
        records.sorted { left, right in
            switch (left.sortOrder, right.sortOrder) {
            case let (leftOrder?, rightOrder?):
                if leftOrder != rightOrder { return leftOrder < rightOrder }
                return left.updatedAt > right.updatedAt
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return left.updatedAt > right.updatedAt
            }
        }
    }

    nonisolated static func normalizedProjectOrdering(_ ordered: [ResearchProject]) -> [ResearchProject] {
        ordered.enumerated().map { index, project in
            var project = project
            project.sortOrder = index
            return project
        }
    }

    private func orderedPapers(_ records: [PaperRecord]) -> [PaperRecord] {
        Self.sortedPapers(records)
    }

    private func orderedExistingWorks(_ records: [ExistingWork]) -> [ExistingWork] {
        Self.sortedExistingWorks(records)
    }

    private func orderedProjects(_ records: [ResearchProject]) -> [ResearchProject] {
        Self.sortedProjects(records)
    }

    private func normalizePaperOrdering(from ordered: [PaperRecord]) {
        papers = Self.normalizedPaperOrdering(ordered)
    }

    private func normalizeExistingWorkOrdering(from ordered: [ExistingWork]) {
        existingWorks = Self.normalizedExistingWorkOrdering(ordered)
    }

    private func normalizeProjectOrdering(from ordered: [ResearchProject]) {
        projects = Self.normalizedProjectOrdering(ordered)
    }

    private func nextPaperSortOrder() -> Int {
        (papers.compactMap(\.sortOrder).min() ?? 0) - 1
    }

    private func nextExistingWorkSortOrder() -> Int {
        (existingWorks.compactMap(\.sortOrder).min() ?? 0) - 1
    }

    private func nextProjectSortOrder() -> Int {
        (projects.compactMap(\.sortOrder).min() ?? 0) - 1
    }

    private func clean(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isPlausibleExtraction(_ paper: ExtractedPaper, publisher: PublisherDefinition) -> Bool {
        let manuscriptID = clean(paper.id)
        let title = clean(paper.title)
        let status = clean(paper.status)
        guard !manuscriptID.isEmpty, !title.isEmpty, !status.isEmpty,
              title.count >= 5, title.count <= 1_200, status.count <= 300 else { return false }
        let rejected = [
            "label", "login", "log in", "sign in", "logout", "password", "username",
            "user name", "action", "action links", "menu", "home", "dashboard",
            "editorial manager", "button", "link", "navigation", "unknown", "n/a",
        ]
        let normalizedID = manuscriptID.lowercased()
        let normalizedTitle = title.lowercased()
        let normalizedStatus = status.lowercased()
        guard !rejected.contains(normalizedID), !rejected.contains(normalizedTitle),
              !rejected.contains(normalizedStatus),
              normalizedID.range(of: #"\.(aspx?|php|html?)($|[?#])"#, options: .regularExpression) == nil,
              !normalizedTitle.contains("forgot password"),
              !normalizedTitle.contains("sign in"),
              !normalizedTitle.contains("log in") else { return false }
        if publisher.kind == "editorial-manager", manuscriptID.range(of: #"^pending:[0-9a-f]{8}$"#, options: .regularExpression) == nil {
            guard manuscriptID != title, manuscriptID.count >= 4, manuscriptID.count <= 160,
                  manuscriptID.rangeOfCharacter(from: .decimalDigits) != nil else { return false }
        }
        return true
    }

    private func preferredJournal(
        incoming: String,
        existing: String?,
        resultURL: String,
        publisher: PublisherDefinition
    ) -> String {
        let incoming = clean(incoming)
        let existing = clean(existing ?? "")
        if let hint = Self.editorialManagerJournalHint(for: resultURL), publisher.kind == "editorial-manager" {
            return hint
        }
        if !incoming.isEmpty, !Self.isGenericPortalJournal(incoming) { return incoming }
        if !existing.isEmpty, !Self.isGenericPortalJournal(existing) { return existing }
        return ""
    }

    private nonisolated static func isGenericPortalJournal(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exactGenericNames = [
            "editorial manager", "springer nature", "wiley", "scholarone manuscripts",
            "未识别期刊", "未填写期刊或会议",
        ]
        if exactGenericNames.contains(normalized) { return true }
        let workflowHeadings = [
            "submissions being", "submissions with", "submissions requiring",
            "submissions sent", "submissions assigned", "manuscripts being",
            "author main menu", "reviewer main menu", "editor main menu",
        ]
        return workflowHeadings.contains(where: normalized.contains)
    }

    private nonisolated static func editorialManagerJournalHint(for urlString: String) -> String? {
        guard let url = URL(string: urlString),
              url.host?.lowercased().hasSuffix("editorialmanager.com") == true else { return nil }
        let code = url.path.split(separator: "/").first?.lowercased()
        switch code {
        case "ksas": return "International Journal of Aeronautical & Space Sciences"
        case "eswa": return "Expert Systems with Applications"
        case "isatrans": return "ISA Transactions"
        default: return nil
        }
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = LibraryPaths.isoFormatter.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    static func portalIdentity(for urlString: String, kind: String) -> String {
        guard let components = URLComponents(string: urlString) else { return urlString.lowercased() }
        let host = (components.host ?? "unknown").lowercased().replacingOccurrences(of: "www.", with: "")
        let parts = components.path.split(separator: "/")
        let pathScopedKinds: Set<String> = [
            "editorial-manager", "scholarone", "editorial-express", "ejournalpress",
            "benchpress", "manuscript-manager", "kriyadocs", "ojs", "janeway",
            "generic", "custom",
        ]
        if pathScopedKinds.contains(kind) {
            return "\(host)/\(parts.first?.lowercased() ?? "")"
        }
        return host
    }

    // MARK: - 静态路径与版本（转发到 LibraryPaths / LibrarySchema）

    static let applicationSupportURL = LibraryPaths.applicationSupport
    static let currentLibraryVersion = LibrarySchema.currentVersion
    static let libraryURL = LibraryPaths.library
    static let attachmentsURL = LibraryPaths.attachments
    static let certificateAttachmentsURL = LibraryPaths.certificateAttachments
    static let managedDocumentsURL = LibraryPaths.managedDocuments
    static let migrationBackupsURL = LibraryPaths.migrationBackups
    static let dayFormatter = LibraryPaths.dayFormatter
    static let migrationTimestampFormatter = LibraryPaths.migrationTimestampFormatter

    static var marketingVersion: String {
        LibrarySchema.marketingVersion
    }
}
