import Foundation

struct PublisherDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String
    let url: String
    let subtitle: String
    let symbol: String
    let brands: String
    let requiresJournalURL: Bool

    init(
        id: String,
        name: String,
        kind: String,
        url: String,
        subtitle: String,
        symbol: String,
        brands: String,
        requiresJournalURL: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.subtitle = subtitle
        self.symbol = symbol
        self.brands = brands
        self.requiresJournalURL = requiresJournalURL
    }

    static let builtIns: [PublisherDefinition] = [
        .init(
            id: "springer",
            name: "Springer Nature",
            kind: "springer",
            url: "https://submission.springernature.com/",
            subtitle: "Springer Nature 投稿系统",
            symbol: "leaf.fill",
            brands: "Springer、BMC 等"
        ),
        .init(
            id: "scholarone",
            name: "ScholarOne",
            kind: "scholarone",
            url: "https://mc.manuscriptcentral.com/",
            subtitle: "ScholarOne Manuscripts",
            symbol: "graduationcap.fill",
            brands: "SAGE、Cambridge、Oxford、IOP 等",
            requiresJournalURL: true
        ),
        .init(
            id: "taylor-francis",
            name: "Taylor & Francis",
            kind: "taylor-francis",
            url: "https://rp.tandfonline.com/dashboard/",
            subtitle: "Author Services",
            symbol: "books.vertical.fill",
            brands: "Taylor & Francis、Routledge"
        ),
        .init(
            id: "wiley",
            name: "Wiley Authors",
            kind: "wiley",
            url: "https://authors.wiley.com/dashboard",
            subtitle: "Wiley 作者中心",
            symbol: "w.circle.fill",
            brands: "Wiley、Hindawi"
        ),
        .init(
            id: "ieee",
            name: "IEEE Author Portal",
            kind: "ieee",
            url: "https://ieee.submission.researchexchange.com/",
            subtitle: "IEEE 作者门户",
            symbol: "bolt.horizontal.circle.fill",
            brands: "IEEE"
        ),
        .init(
            id: "acs",
            name: "ACS Paragon Plus",
            kind: "acs",
            url: "https://acsparagonplus.acs.org/",
            subtitle: "ACS 投稿系统",
            symbol: "atom",
            brands: "American Chemical Society"
        ),
        .init(
            id: "openreview",
            name: "OpenReview",
            kind: "openreview",
            url: "https://openreview.net/",
            subtitle: "开放评审平台",
            symbol: "bubble.left.and.text.bubble.right.fill",
            brands: "ICLR、NeurIPS workshops 等"
        ),
        .init(
            id: "editorial-manager",
            name: "Editorial Manager",
            kind: "editorial-manager",
            url: "https://www.editorialmanager.com/",
            subtitle: "Editorial Manager 投稿系统",
            symbol: "doc.text.magnifyingglass",
            brands: "Elsevier、PLOS、Cell Press 等",
            requiresJournalURL: true
        ),
        .init(
            id: "mdpi",
            name: "MDPI SuSy",
            kind: "mdpi",
            url: "https://susy.mdpi.com/",
            subtitle: "MDPI 投稿系统",
            symbol: "m.circle.fill",
            brands: "MDPI"
        ),
        .init(
            id: "nature",
            name: "Nature Portfolio",
            kind: "nature",
            url: "https://submission.nature.com/",
            subtitle: "Nature Portfolio 投稿门户",
            symbol: "globe.europe.africa.fill",
            brands: "Nature 及子刊"
        ),
        .init(
            id: "aip",
            name: "AIP Publishing",
            kind: "aip",
            url: "https://pop.peerx-press.org/",
            subtitle: "AIP Peer X-Press",
            symbol: "waveform.path.ecg.rectangle.fill",
            brands: "AIP Publishing"
        ),
        .init(
            id: "frontiers",
            name: "Frontiers",
            kind: "frontiers",
            url: "https://www.frontiersin.org/my-frontiers",
            subtitle: "My Frontiers 投稿与评审平台",
            symbol: "person.crop.circle.badge.checkmark",
            brands: "Frontiers 系列期刊"
        ),
        .init(
            id: "editorial-express",
            name: "Editorial Express",
            kind: "editorial-express",
            url: "https://editorialexpress.com/e-editor/",
            subtitle: "经济学与金融学常用投稿系统",
            symbol: "building.columns.fill",
            brands: "Econometrica、RFS 等",
            requiresJournalURL: true
        ),
        .init(
            id: "copernicus",
            name: "Copernicus Office",
            kind: "copernicus",
            url: "https://editor.copernicus.org/",
            subtitle: "Copernicus Office Editor",
            symbol: "cloud.sun.fill",
            brands: "EGU、Copernicus Publications"
        ),
        .init(
            id: "ejournalpress",
            name: "eJournalPress",
            kind: "ejournalpress",
            url: "https://customers.ejpress.com/",
            subtitle: "eJournalPress / EJPress",
            symbol: "newspaper.fill",
            brands: "学协会与医学期刊",
            requiresJournalURL: true
        ),
        .init(
            id: "benchpress",
            name: "HighWire BenchPress",
            kind: "benchpress",
            url: "https://www.highwirepress.com/solutions/highwire-benchpress/",
            subtitle: "HighWire 投稿与评审系统",
            symbol: "rectangle.and.pencil.and.ellipsis",
            brands: "ASH、bioRxiv/medRxiv 等",
            requiresJournalURL: true
        ),
        .init(
            id: "manuscript-manager",
            name: "Manuscript Manager",
            kind: "manuscript-manager",
            url: "https://www.manuscriptmanager.com/",
            subtitle: "独立期刊投稿与同行评审系统",
            symbol: "tray.full.fill",
            brands: "独立期刊与学协会期刊",
            requiresJournalURL: true
        ),
        .init(
            id: "scholastica",
            name: "Scholastica",
            kind: "scholastica",
            url: "https://app.scholasticahq.com/users/sign_in",
            subtitle: "投稿与同行评审管理平台",
            symbol: "checkmark.seal.fill",
            brands: "独立期刊、法学与人文社科期刊"
        ),
        .init(
            id: "kriyadocs",
            name: "Kriyadocs",
            kind: "kriyadocs",
            url: "https://www.kriyadocs.com/products-peer-review",
            subtitle: "投稿、评审与出版工作流",
            symbol: "doc.text.fill",
            brands: "采用 Kriyadocs 的出版机构",
            requiresJournalURL: true
        ),
        .init(
            id: "ojs",
            name: "Open Journal Systems",
            kind: "ojs",
            url: "https://pkp.sfu.ca/software/ojs/",
            subtitle: "PKP OJS 开源投稿系统",
            symbol: "square.stack.3d.up.fill",
            brands: "高校、学协会与独立期刊",
            requiresJournalURL: true
        ),
        .init(
            id: "janeway",
            name: "Janeway",
            kind: "janeway",
            url: "https://janeway.systems/",
            subtitle: "开源投稿、评审与出版平台",
            symbol: "arrow.triangle.branch",
            brands: "大学出版社与开放获取期刊",
            requiresJournalURL: true
        ),
    ]
}

struct PortalAccount: Codable, Identifiable, Hashable {
    var id: String
    var publisherID: String
    var publisherName: String
    var kind: String
    var name: String
    var url: String
    var identity: String
    var createdAt: Date
    var lastChecked: Date?
    var lastError: String?

    var publisher: PublisherDefinition {
        PublisherDefinition.builtIns.first(where: { $0.id == publisherID })
            ?? PublisherDefinition(
                id: publisherID,
                name: publisherName,
                kind: kind,
                url: url,
                subtitle: "自定义投稿网站",
                symbol: "safari.fill",
                brands: URL(string: url)?.host ?? "自定义来源"
            )
    }
}

struct StatusEvent: Codable, Hashable, Identifiable {
    var status: String
    var checkedAt: Date
    var id: String { "\(checkedAt.timeIntervalSince1970)-\(status)" }
}

struct PaperRecord: Codable, Hashable, Identifiable {
    var key: String
    var sourceID: String
    var site: String
    var url: String
    var manuscriptID: String
    var displayManuscriptID: String { manuscriptID.hasPrefix("pending:") ? "期刊尚未分配稿号" : manuscriptID }
    var title: String
    var journal: String
    var status: String
    var checkedAt: Date
    var statusSince: Date
    var statusSinceSource: String
    var previousStatus: String?
    var changed: Bool
    var hidden: Bool
    var history: [StatusEvent]
    var submissionHistory: String?
    var sortOrder: Int? = nil

    var id: String { key }
    var isManual: Bool { sourceID == "manual" }
}

enum ExistingWorkType: String, Codable, CaseIterable, Identifiable {
    case journalArticle
    case conferencePaper
    case graduationThesis
    case book
    case bookChapter
    case patent
    case dataset
    case software
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .journalArticle: AppLocalization.text("期刊论文")
        case .conferencePaper: AppLocalization.text("会议论文")
        case .graduationThesis: AppLocalization.text("毕业论文")
        case .book: AppLocalization.text("专著")
        case .bookChapter: AppLocalization.text("书籍章节")
        case .patent: AppLocalization.text("专利")
        case .dataset: AppLocalization.text("数据集")
        case .software: AppLocalization.text("软件成果")
        case .other: AppLocalization.text("其他成果")
        }
    }

    var symbol: String {
        switch self {
        case .journalArticle: "doc.text.fill"
        case .conferencePaper: "person.3.fill"
        case .graduationThesis: "graduationcap.fill"
        case .book: "book.closed.fill"
        case .bookChapter: "books.vertical.fill"
        case .patent: "lightbulb.fill"
        case .dataset: "externaldrive.fill"
        case .software: "chevron.left.forwardslash.chevron.right"
        case .other: "checkmark.seal.fill"
        }
    }

}

enum PatentType: String, Codable, CaseIterable, Identifiable {
    case invention
    case utilityModel
    case design

    var id: String { rawValue }

    var title: String {
        switch self {
        case .invention: AppLocalization.text("发明专利")
        case .utilityModel: AppLocalization.text("实用新型")
        case .design: AppLocalization.text("外观设计")
        }
    }
}

enum AuthorPosition: String, Codable, CaseIterable, Identifiable {
    case first
    case corresponding
    case second
    case third
    case fourth
    case fifth
    case beyondFifth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .first: AppLocalization.text("一作")
        case .corresponding: AppLocalization.text("通讯作者")
        case .second: AppLocalization.text("二作")
        case .third: AppLocalization.text("三作")
        case .fourth: AppLocalization.text("四作")
        case .fifth: AppLocalization.text("五作")
        case .beyondFifth: AppLocalization.text("五作+")
        }
    }
}

enum JournalMetricGroup: String, Codable, CaseIterable {
    case internationalIndex
    case casPartition
    case impact
    case chineseCore
    case other

    var title: String {
        switch self {
        case .internationalIndex: AppLocalization.text("国际收录")
        case .casPartition: AppLocalization.text("中科院分区（2025）")
        case .impact: AppLocalization.text("影响指标")
        case .chineseCore: AppLocalization.text("中文核心")
        case .other: AppLocalization.text("其他评价")
        }
    }
}

struct JournalMetricItem: Codable, Hashable, Identifiable {
    var key: String
    var label: String
    var value: String
    var group: JournalMetricGroup
    var order: Int

    var id: String { key }

    var displayText: String {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanValue == "是" || cleanLabel.caseInsensitiveCompare(cleanValue) == .orderedSame {
            return cleanLabel
        }
        return [cleanLabel, cleanValue].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct JournalMetricsSnapshot: Codable, Hashable {
    var query: String
    var matchedJournalName: String
    var source: String
    var casEdition: String
    var lookedUpAt: Date
    var items: [JournalMetricItem]

    func items(in group: JournalMetricGroup) -> [JournalMetricItem] {
        let sorted = items.filter { $0.group == group }.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.label < $1.label
        }
        var seen = Set<String>()
        return sorted.filter {
            seen.insert($0.displayText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted
        }
    }

    var summaryItems: [JournalMetricItem] {
        let priorities = [
            "sci", "ssci", "esci", "eii", "ei", "sciUp", "sciif",
            "pku", "cssci", "cscd", "zhongguokejihexin", "ami",
        ]
        let sorted = items.sorted {
            let left = priorities.firstIndex(of: $0.key) ?? priorities.count + $0.order
            let right = priorities.firstIndex(of: $1.key) ?? priorities.count + $1.order
            return left < right
        }
        var seen = Set<String>()
        return sorted.filter {
            seen.insert($0.displayText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted
        }
    }
}

enum DocumentLibraryKind: String, Codable, CaseIterable, Identifiable {
    case experimentData
    case summaryReports
    case importantLiterature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .experimentData: AppLocalization.text("实验数据")
        case .summaryReports: AppLocalization.text("总结报告")
        case .importantLiterature: AppLocalization.text("重要文献")
        }
    }

    var symbol: String {
        switch self {
        case .experimentData: "externaldrive.fill"
        case .summaryReports: "doc.text.fill"
        case .importantLiterature: "books.vertical.fill"
        }
    }

    var folderPrompt: String {
        switch self {
        case .experimentData: AppLocalization.text("按项目创建文件夹，集中管理实验与分析文件")
        case .summaryReports: AppLocalization.text("按主题或周期创建文件夹，整理周报、月报与汇报材料")
        case .importantLiterature: AppLocalization.text("按研究主题创建文件夹，保存真正重要的参考资料")
        }
    }
}

struct DocumentFolder: Codable, Hashable, Identifiable {
    var id: String
    var libraryKind: DocumentLibraryKind
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Int? = nil
}

struct ManagedDocument: Codable, Hashable, Identifiable {
    var id: String
    var folderID: String
    var originalName: String
    var displayName: String
    var storedName: String
    var fileExtension: String
    var tags: [String]
    var byteCount: Int64
    var uploadedAt: Date
    var updatedAt: Date
    var contentText: String? = nil
    var contentIndexedAt: Date? = nil
    var sortOrder: Int? = nil
}

enum ManagedDocumentSort: String, CaseIterable, Identifiable {
    case uploadTime
    case tag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uploadTime: AppLocalization.text("上传时间")
        case .tag: AppLocalization.text("标签")
        }
    }
}

struct WorkAttachment: Codable, Hashable, Identifiable {
    var id: String
    var originalName: String
    var storedName: String
    var kind: String
    var addedAt: Date

    var symbol: String {
        switch kind {
        case "pdf": "doc.richtext.fill"
        case "image": "photo.fill"
        default: "paperclip"
        }
    }

}

struct ProjectStep: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var details: String
    var startDate: Date
    var endDate: Date
    var isCompleted: Bool

    var normalizedEndDate: Date { max(startDate, endDate) }
}

struct ResearchProject: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var content: String
    var steps: [ProjectStep]
    var createdAt: Date
    var updatedAt: Date
    var sortOrder: Int? = nil

    var timelineStart: Date? { steps.map(\.startDate).min() }
    var timelineEnd: Date? { steps.map(\.normalizedEndDate).max() }
    var completedStepCount: Int { steps.filter(\.isCompleted).count }
    var isCompleted: Bool { !steps.isEmpty && completedStepCount == steps.count }
    var progress: Double {
        guard !steps.isEmpty else { return 0 }
        return Double(completedStepCount) / Double(steps.count)
    }
}

struct CertificateRecord: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var eventDate: Date
    var tags: [String]
    var attachments: [WorkAttachment]
    var createdAt: Date
    var updatedAt: Date
}

struct FundingRecord: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var amount: Double
    var year: Int
    var months: [Int]
    var receivingAccount: String
    var createdAt: Date
    var updatedAt: Date

    func isScheduled(year targetYear: Int, month targetMonth: Int) -> Bool {
        year == targetYear && months.contains(targetMonth)
    }
}

struct ExistingWork: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var type: ExistingWorkType
    var venue: String
    var authors: String
    var completedAt: Date
    var identifier: String
    var url: String
    var notes: String
    var attachments: [WorkAttachment]
    var createdAt: Date
    var updatedAt: Date
    var patentType: PatentType?
    var journalISSN: String?
    var journalMetrics: JournalMetricsSnapshot?
    var authorPosition: AuthorPosition?
    var sortOrder: Int? = nil
}

enum TrashItemKind: String, Codable, CaseIterable {
    case submission
    case work
    case project
    case documentFolder
    case document
    case certificate
    case funding
    case workAttachment
    case certificateAttachment

    var title: String {
        switch self {
        case .submission: AppLocalization.text("在投论文")
        case .work: AppLocalization.text("成果")
        case .project: AppLocalization.text("项目")
        case .documentFolder: AppLocalization.text("资料文件夹")
        case .document: AppLocalization.text("资料文件")
        case .certificate: AppLocalization.text("证书")
        case .funding: AppLocalization.text("资金记录")
        case .workAttachment, .certificateAttachment: AppLocalization.text("附件")
        }
    }

    var symbol: String {
        switch self {
        case .submission: "paperplane.fill"
        case .work: "checkmark.seal.fill"
        case .project: "calendar.badge.clock"
        case .documentFolder: "folder.fill"
        case .document: "doc.fill"
        case .certificate: "checkmark.rectangle.stack.fill"
        case .funding: "banknote.fill"
        case .workAttachment, .certificateAttachment: "paperclip"
        }
    }
}

struct TrashItem: Codable, Hashable, Identifiable {
    var id: String
    var kind: TrashItemKind
    var title: String
    var deletedAt: Date
    var paper: PaperRecord? = nil
    var work: ExistingWork? = nil
    var project: ResearchProject? = nil
    var documentFolder: DocumentFolder? = nil
    var documents: [ManagedDocument] = []
    var certificate: CertificateRecord? = nil
    var funding: FundingRecord? = nil
    var attachment: WorkAttachment? = nil
    var parentID: String? = nil
}

struct ExtractedPaper: Codable {
    var id: String
    var title: String
    var journal: String
    var status: String
    var statusSince: String?
    var statusSinceSource: String?
    var submissionHistory: String?
}

struct ExtractionResult: Codable {
    var site: String
    var url: String
    var checkedAt: String
    var papers: [ExtractedPaper]
}

struct PersistedLibrary: Codable {
    var version: Int
    var papers: [PaperRecord]
    var portals: [PortalAccount]
    var existingWorks: [ExistingWork]
    var projects: [ResearchProject]
    var certificates: [CertificateRecord]
    var fundingRecords: [FundingRecord]
    var documentFolders: [DocumentFolder]
    var managedDocuments: [ManagedDocument]
    var trashItems: [TrashItem]
    var rewardCity: RewardCityState

    init(
        version: Int = 32,
        papers: [PaperRecord] = [],
        portals: [PortalAccount] = [],
        existingWorks: [ExistingWork] = [],
        projects: [ResearchProject] = [],
        certificates: [CertificateRecord] = [],
        fundingRecords: [FundingRecord] = [],
        documentFolders: [DocumentFolder] = [],
        managedDocuments: [ManagedDocument] = [],
        trashItems: [TrashItem] = [],
        rewardCity: RewardCityState = RewardCityState()
    ) {
        self.version = version
        self.papers = papers
        self.portals = portals
        self.existingWorks = existingWorks
        self.projects = projects
        self.certificates = certificates
        self.fundingRecords = fundingRecords
        self.documentFolders = documentFolders
        self.managedDocuments = managedDocuments
        self.trashItems = trashItems
        self.rewardCity = rewardCity
    }

    private enum CodingKeys: String, CodingKey {
        case version, papers, portals, existingWorks, projects, certificates, fundingRecords
        case documentFolders, managedDocuments, trashItems, rewardCity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        papers = try container.decodeIfPresent([PaperRecord].self, forKey: .papers) ?? []
        portals = try container.decodeIfPresent([PortalAccount].self, forKey: .portals) ?? []
        existingWorks = try container.decodeIfPresent([ExistingWork].self, forKey: .existingWorks) ?? []
        projects = try container.decodeIfPresent([ResearchProject].self, forKey: .projects) ?? []
        certificates = try container.decodeIfPresent([CertificateRecord].self, forKey: .certificates) ?? []
        fundingRecords = try container.decodeIfPresent([FundingRecord].self, forKey: .fundingRecords) ?? []
        documentFolders = try container.decodeIfPresent([DocumentFolder].self, forKey: .documentFolders) ?? []
        managedDocuments = try container.decodeIfPresent([ManagedDocument].self, forKey: .managedDocuments) ?? []
        trashItems = try container.decodeIfPresent([TrashItem].self, forKey: .trashItems) ?? []
        rewardCity = try container.decodeIfPresent(RewardCityState.self, forKey: .rewardCity) ?? RewardCityState()
    }
}

struct ImportOutcome {
    let importedCount: Int
    let changedCount: Int
    let portal: PortalAccount
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case existing
    case projects
    case experimentData
    case summaryReports
    case importantLiterature
    case certificates
    case funding
    case rewardCity
    case changed
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: AppLocalization.text("在投管理")
        case .existing: AppLocalization.text("成果管理")
        case .projects: AppLocalization.text("项目管理")
        case .experimentData: AppLocalization.text("实验数据")
        case .summaryReports: AppLocalization.text("总结报告")
        case .importantLiterature: AppLocalization.text("重要文献")
        case .certificates: AppLocalization.text("证书管理")
        case .funding: AppLocalization.text("资金管理")
        case .rewardCity: AppLocalization.text("研究城")
        case .changed: AppLocalization.text("状态更新")
        case .hidden: AppLocalization.text("已归档")
        }
    }

    var symbol: String {
        switch self {
        case .all: "paperplane.fill"
        case .existing: "checkmark.seal.fill"
        case .projects: "calendar.badge.clock"
        case .experimentData: "externaldrive.fill"
        case .summaryReports: "doc.text.fill"
        case .importantLiterature: "books.vertical.fill"
        case .certificates: "rectangle.badge.checkmark"
        case .funding: "banknote.fill"
        case .rewardCity: "building.2.crop.circle.fill"
        case .changed: "bell.badge.fill"
        case .hidden: "archivebox.fill"
        }
    }

    var isSubmissionFilter: Bool {
        switch self {
        case .all, .changed, .hidden: true
        case .existing, .projects, .experimentData, .summaryReports, .importantLiterature, .certificates, .funding, .rewardCity: false
        }
    }

    var documentLibraryKind: DocumentLibraryKind? {
        switch self {
        case .experimentData: .experimentData
        case .summaryReports: .summaryReports
        case .importantLiterature: .importantLiterature
        default: nil
        }
    }
}
