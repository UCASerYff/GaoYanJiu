import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct ManualSubmissionEditor: View {
    @EnvironmentObject private var store: PaperStore
    @Environment(\.dismiss) private var dismiss

    private let existingID: String?
    @State private var title: String
    @State private var venue: String
    @State private var manuscriptID: String
    @State private var status: String
    @State private var statusSince: Date
    @State private var portalURL: String
    @State private var notes: String

    private static let commonStatuses = [
        "准备投稿", "已投稿", "编辑初审", "外审中", "小修", "大修", "修回审理中", "已接受", "已拒稿", "已撤稿",
    ]

    init(paper: PaperRecord?) {
        existingID = paper?.id
        _title = State(initialValue: paper?.title ?? "")
        _venue = State(initialValue: paper?.journal == "未填写期刊或会议" ? "" : paper?.journal ?? "")
        _manuscriptID = State(initialValue: paper?.manuscriptID == "未填写" ? "" : paper?.manuscriptID ?? "")
        _status = State(initialValue: paper?.status ?? "已投稿")
        _statusSince = State(initialValue: paper?.statusSince ?? Date())
        _portalURL = State(initialValue: paper?.url ?? "")
        _notes = State(initialValue: paper?.submissionHistory ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader(
                title: existingID == nil ? "手动添加在投论文" : "编辑在投论文",
                subtitle: "适用于会议、期刊自建系统等无法自动导入的情况。"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    EditorGroup(title: "基本信息") {
                        TextField(AppLocalization.text("论文标题（必填）"), text: $title)
                        TextField(AppLocalization.text("期刊或会议名称"), text: $venue)
                        TextField(AppLocalization.text("稿件编号（可选）"), text: $manuscriptID)
                    }

                    EditorGroup(title: "当前状态") {
                        HStack(spacing: 10) {
                            TextField(AppLocalization.text("状态（必填）"), text: $status)
                            Menu(AppLocalization.text("常用状态")) {
                                ForEach(Self.commonStatuses, id: \.self) { item in
                                    Button(item) { status = item }
                                }
                            }
                        }
                        DatePicker(AppLocalization.text("进入该状态的日期"), selection: $statusSince, displayedComponents: [.date])
                            .datePickerStyle(.field)
                        if existingID != nil {
                            Text(AppLocalization.text("如果修改状态，之前的状态会自动保留在历史记录中。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    EditorGroup(title: "补充信息") {
                        TextField(AppLocalization.text("投稿网页链接（可选）"), text: $portalURL)
                        Text(AppLocalization.text("备注"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        NotesEditor(text: $notes, prompt: "记录投稿、催稿或与会议主办方沟通的信息…")
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                Spacer()
                Button(AppLocalization.text("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppLocalization.text(existingID == nil ? "添加" : "保存")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 680, height: 670)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        store.saveManualSubmission(
            existingID: existingID,
            title: title,
            venue: venue,
            manuscriptID: manuscriptID,
            status: status,
            statusSince: statusSince,
            portalURL: normalizedURL(portalURL),
            notes: notes
        )
        dismiss()
    }
}

struct ExistingWorksDashboard: View {
    @EnvironmentObject private var store: PaperStore
    let works: [ExistingWork]
    let isSearching: Bool
    let openAction: (ExistingWork) -> Void
    let createAction: () -> Void
    @State private var draggedWorkID: String?
    @State private var editingWork: ExistingWork?
    @State private var workPendingDeletion: ExistingWork?

    var body: some View {
        Group {
        if works.isEmpty {
            ListEmptyStateView(
                icon: "checkmark.seal",
                title: AppLocalization.text(isSearching ? "没有找到匹配的成果" : "还没有成果"),
                subtitle: AppLocalization.text(isSearching
                     ? "试试使用其他标题、作者、发表载体或 DOI 关键词。"
                     : "手动建立期刊论文、会议论文、专利等成果，并统一保管 PDF 和图片附件。"),
                buttonTitle: isSearching ? nil : AppLocalization.text("新建成果"),
                buttonAction: isSearching ? nil : createAction
            )
        } else {
            ScrollView {
                VStack(spacing: 18) {
                    ExistingWorksAnalytics(works: works)

                    LazyVStack(spacing: 12) {
                        ForEach(works) { work in
                            ExistingWorkCard(work: work) { openAction(work) }
                                .contextMenu { workContextMenu(for: work) }
                                .onDrag {
                                    draggedWorkID = work.id
                                    return NSItemProvider(object: work.id as NSString)
                                }
                                .onDrop(
                                    of: [UTType.plainText],
                                    delegate: ReorderDropDelegate.existingWork(
                                        targetID: work.id,
                                        draggedID: $draggedWorkID,
                                        store: store
                                    )
                                )
                        }
                    }
                }
                .frame(maxWidth: 1100)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
        }
        .sheet(item: $editingWork) { work in
            ExistingWorkEditor(work: work)
                .environmentObject(store)
        }
        .alert(
            AppLocalization.text("删除该成果及其附件？"),
            isPresented: Binding(
                get: { workPendingDeletion != nil },
                set: { if !$0 { workPendingDeletion = nil } }
            )
        ) {
            Button(AppLocalization.text("取消"), role: .cancel) {}
            Button(AppLocalization.text("删除"), role: .destructive) {
                if let work = workPendingDeletion { store.deleteExistingWork(work) }
                workPendingDeletion = nil
            }
        } message: {
            Text(AppLocalization.text("成果记录及附件副本会移入回收站，可在30天内恢复。"))
        }
    }

    @ViewBuilder
    private func workContextMenu(for work: ExistingWork) -> some View {
        Button {
            openAction(work)
        } label: {
            Label(AppLocalization.text("查看详情"), systemImage: "doc.text.magnifyingglass")
        }
        Button {
            editingWork = work
        } label: {
            Label(AppLocalization.text("编辑"), systemImage: "square.and.pencil")
        }
        if !work.attachments.isEmpty {
            Button {
                revealAttachmentsInFinder(for: work)
            } label: {
                Label(AppLocalization.text("在访达中显示"), systemImage: "folder")
            }
        }
        Divider()
        Button(role: .destructive) {
            workPendingDeletion = work
        } label: {
            Label(AppLocalization.text("删除"), systemImage: "trash")
        }
    }

    private func revealAttachmentsInFinder(for work: ExistingWork) {
        let urls = work.attachments
            .map { store.attachmentURL($0, for: work) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

private struct AnalyticsDatum: Identifiable {
    let id: String
    let label: String
    let count: Int
}

private struct ExistingWorksAnalytics: View {
    let works: [ExistingWork]

    private var typeData: [AnalyticsDatum] {
        ExistingWorkType.allCases.flatMap { type -> [AnalyticsDatum] in
            if type == .patent {
                var patentItems = PatentType.allCases.compactMap { patentType -> AnalyticsDatum? in
                    let count = works.filter { $0.type == .patent && $0.patentType == patentType }.count
                    return count == 0 ? nil : AnalyticsDatum(
                        id: "patent-\(patentType.rawValue)", label: patentType.title, count: count
                    )
                }
                let unspecified = works.filter { $0.type == .patent && $0.patentType == nil }.count
                if unspecified > 0 {
                    patentItems.append(AnalyticsDatum(
                        id: "patent-unspecified", label: AppLocalization.text("未细分专利"), count: unspecified
                    ))
                }
                return patentItems
            }
            let count = works.filter { $0.type == type }.count
            return count == 0 ? [] : [AnalyticsDatum(id: type.rawValue, label: type.title, count: count)]
        }
    }

    private var authorData: [AnalyticsDatum] {
        AuthorPosition.allCases.map { position in
            AnalyticsDatum(
                id: position.rawValue,
                label: position.title,
                count: works.filter { $0.authorPosition == position }.count
            )
        }
    }

    private var unassignedCount: Int {
        works.filter { $0.authorPosition == nil }.count
    }

    private var yearData: [AnalyticsDatum] {
        Dictionary(grouping: works) {
            Calendar.current.component(.year, from: $0.completedAt)
        }
        .map { year, records in
            AnalyticsDatum(id: String(year), label: String(year), count: records.count)
        }
        .sorted { $0.label < $1.label }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                AnalyticsCard(title: "成果类别分布", subtitle: "按当前列表中的成果类型统计") {
                    Chart(typeData) { item in
                        BarMark(
                            x: .value(AppLocalization.text("数量"), item.count),
                            y: .value(AppLocalization.text("类别"), item.label)
                        )
                        .foregroundStyle(AppTheme.blue.gradient)
                        .cornerRadius(3)
                        .annotation(position: .trailing) {
                            Text("\(item.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(position: .bottom) {
                            AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                            AxisValueLabel()
                        }
                    }
                    .frame(height: 215)
                    .accessibilityChartDescriptor(ChartAccessibility.descriptor(
                        title: AppLocalization.text("成果类别分布"),
                        summary: AppLocalization.format(
                            "共 %d 种类别，合计 %d 项成果",
                            typeData.count,
                            typeData.reduce(0) { $0 + $1.count }
                        ),
                        categoryAxisTitle: AppLocalization.text("类别"),
                        valueAxisTitle: AppLocalization.text("数量"),
                        points: typeData.map { (category: $0.label, value: Double($0.count)) },
                        valueDescription: { AppLocalization.format("%d 项", Int($0)) }
                    ))
                }

                AnalyticsCard(title: "我的署名分布", subtitle: "一作、通讯作者及其他署名顺序") {
                    VStack(alignment: .leading, spacing: 8) {
                        Chart(authorData) { item in
                            BarMark(
                                x: .value(AppLocalization.text("署名顺序"), item.label),
                                y: .value(AppLocalization.text("数量"), item.count)
                            )
                            .foregroundStyle(AppTheme.teal.gradient)
                            .cornerRadius(3)
                            .annotation(position: .top) {
                                if item.count > 0 {
                                    Text("\(item.count)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading) {
                                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                                AxisValueLabel()
                            }
                        }
                        .frame(height: 185)
                        .accessibilityChartDescriptor(ChartAccessibility.descriptor(
                            title: AppLocalization.text("我的署名分布"),
                            summary: AppLocalization.format(
                                "共 %d 种署名顺序，合计 %d 项成果",
                                authorData.count,
                                authorData.reduce(0) { $0 + $1.count }
                            ),
                            categoryAxisTitle: AppLocalization.text("署名顺序"),
                            valueAxisTitle: AppLocalization.text("数量"),
                            points: authorData.map { (category: $0.label, value: Double($0.count)) },
                            valueDescription: { AppLocalization.format("%d 项", Int($0)) }
                        ))

                        Text(unassignedCount == 0
                             ? AppLocalization.text("所有成果均已设置署名顺序")
                             : AppLocalization.format("另有 %d 项成果尚未设置署名顺序", unassignedCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            AnalyticsCard(title: "年度成果增长趋势", subtitle: "按完成或发表年份统计") {
                Chart(yearData) { item in
                    BarMark(
                        x: .value(AppLocalization.text("年份"), item.label),
                        y: .value(AppLocalization.text("成果数量"), item.count)
                    )
                    .foregroundStyle(AppTheme.blue.opacity(0.24))
                    .cornerRadius(3)

                    LineMark(
                        x: .value(AppLocalization.text("年份"), item.label),
                        y: .value(AppLocalization.text("成果数量"), item.count)
                    )
                    .foregroundStyle(AppTheme.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))

                    PointMark(
                        x: .value(AppLocalization.text("年份"), item.label),
                        y: .value(AppLocalization.text("成果数量"), item.count)
                    )
                    .foregroundStyle(AppTheme.blue)
                    .annotation(position: .top) {
                        Text("\(item.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel()
                    }
                }
                .frame(height: 220)
                .accessibilityChartDescriptor(ChartAccessibility.descriptor(
                    title: AppLocalization.text("年度成果增长趋势"),
                    summary: AppLocalization.format(
                        "覆盖 %d 个年份，合计 %d 项成果",
                        yearData.count,
                        yearData.reduce(0) { $0 + $1.count }
                    ),
                    categoryAxisTitle: AppLocalization.text("年份"),
                    valueAxisTitle: AppLocalization.text("成果数量"),
                    points: yearData.map { (category: $0.label, value: Double($0.count)) },
                    valueDescription: { AppLocalization.format("%d 项", Int($0)) }
                ))
            }
        }
    }
}

private struct AnalyticsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.text(title))
                    .font(.headline)
                Text(AppLocalization.text(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
}

private struct ExistingWorkCard: View {
    let work: ExistingWork
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: work.type.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.teal)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(work.type == .patent ? (work.patentType?.title ?? work.type.title) : work.type.title)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.blue)
                        Text(Formatters.workDate.string(from: work.completedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(work.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let metrics = work.journalMetrics {
                        HStack(spacing: 6) {
                            ForEach(Array(metrics.summaryItems.prefix(3))) { item in
                                Text(item.displayText)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(AppTheme.indigo)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(AppTheme.blue.opacity(0.08), in: Capsule())
                            }
                        }
                        .lineLimit(1)
                    }
                    Text([work.venue, work.authors].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                if !work.attachments.isEmpty {
                    Label("\(work.attachments.count)", systemImage: "paperclip")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(AppLocalization.format("%d 个附件", work.attachments.count))
                }
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Image(systemName: "line.3.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                    .help(AppLocalization.text("上下拖动调整顺序"))
            }
            .padding(17)
            .contentShape(Rectangle())
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .listHoverHighlight()
    }
}

// V4.6 batch-Q2：ReorderDropDelegate 已泛型化到 SharedListComponents.swift，
// 成果列表改用 ReorderDropDelegate.existingWork 工厂。

struct ExistingWorkEditor: View {
    @EnvironmentObject private var store: PaperStore
    @Environment(\.dismiss) private var dismiss

    private let existingID: String?
    @State private var title: String
    @State private var type: ExistingWorkType
    @State private var venue: String
    @State private var authors: String
    @State private var authorPosition: AuthorPosition?
    @State private var completedAt: Date
    @State private var identifier: String
    @State private var url: String
    @State private var notes: String
    @State private var patentType: PatentType
    @State private var journalISSN: String
    @State private var journalMetrics: JournalMetricsSnapshot?
    @State private var secretKey: String
    @State private var isLookingUp = false
    @State private var lookupMessage: String?
    @State private var lookupSucceeded = false
    @State private var journalSuggestions: [JournalSuggestion] = []
    @State private var isLoadingSuggestions = false
    @State private var suggestionTask: Task<Void, Never>?
    @State private var suppressSuggestionRefresh = false

    init(work: ExistingWork?) {
        existingID = work?.id
        _title = State(initialValue: work?.title ?? "")
        _type = State(initialValue: work?.type ?? .journalArticle)
        _venue = State(initialValue: work?.venue ?? "")
        _authors = State(initialValue: work?.authors ?? "")
        _authorPosition = State(initialValue: work?.authorPosition)
        _completedAt = State(initialValue: work?.completedAt ?? Date())
        _identifier = State(initialValue: work?.identifier ?? "")
        _url = State(initialValue: work?.url ?? "")
        _notes = State(initialValue: work?.notes ?? "")
        _patentType = State(initialValue: work?.patentType ?? .invention)
        _journalISSN = State(initialValue: work?.journalISSN ?? "")
        _journalMetrics = State(initialValue: work?.journalMetrics)
        _secretKey = State(initialValue: EasyScholarSecretKeyStore.load())
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader(
                title: existingID == nil ? "新建成果" : "编辑成果",
                subtitle: "整理已发表、已接收或已完成的学术成果。"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    EditorGroup(title: "成果信息") {
                        TextField(AppLocalization.text("成果标题（必填）"), text: $title)
                        Picker(AppLocalization.text("成果类型"), selection: $type) {
                            ForEach(ExistingWorkType.allCases) { item in
                                Label(item.title, systemImage: item.symbol).tag(item)
                            }
                        }
                        if type == .patent {
                            Picker(AppLocalization.text("专利类型"), selection: $patentType) {
                                ForEach(PatentType.allCases) { item in
                                    Text(item.title).tag(item)
                                }
                            }
                        }
                        DatePicker(AppLocalization.text("完成或发表日期"), selection: $completedAt, displayedComponents: [.date])
                            .datePickerStyle(.field)
                        if type == .journalArticle {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    TextField(AppLocalization.text("输入期刊名称以搜索并选择"), text: $venue)
                                        .onChange(of: venue) { value in
                                            scheduleJournalSuggestions(for: value)
                                        }
                                    if isLoadingSuggestions { ProgressView().controlSize(.small) }
                                }
                                if !journalSuggestions.isEmpty {
                                    VStack(spacing: 0) {
                                        ForEach(Array(journalSuggestions.prefix(6).enumerated()), id: \.element.id) { index, suggestion in
                                            Button { selectJournalSuggestion(suggestion) } label: {
                                                HStack(spacing: 10) {
                                                    Image(systemName: "books.vertical.fill")
                                                        .foregroundStyle(AppTheme.blue)
                                                        .accessibilityHidden(true)
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(suggestion.title)
                                                            .font(.callout.weight(.medium))
                                                            .foregroundStyle(.primary)
                                                            .lineLimit(1)
                                                        Text([suggestion.issn, suggestion.publisher]
                                                            .filter { !$0.isEmpty }.joined(separator: " · "))
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                            .lineLimit(1)
                                                    }
                                                    Spacer()
                                                    Image(systemName: "arrow.turn.down.left")
                                                        .font(.caption)
                                                        .foregroundStyle(.tertiary)
                                                        .accessibilityHidden(true)
                                                }
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 7)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            if index < min(journalSuggestions.count, 6) - 1 { Divider() }
                                        }
                                    }
                                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
                                }
                            }
                        } else {
                            TextField(AppLocalization.text("期刊、会议、出版社或授权机构"), text: $venue)
                        }
                        TextField(AppLocalization.text("作者（可选）"), text: $authors)
                        Picker(AppLocalization.text("我的署名顺序"), selection: $authorPosition) {
                            Text(AppLocalization.text("未设置 / 不适用")).tag(nil as AuthorPosition?)
                            ForEach(AuthorPosition.allCases) { item in
                                Text(item.title).tag(Optional(item))
                            }
                        }
                    }

                    if type == .journalArticle {
                        EditorGroup(title: "期刊评价") {
                            TextField(AppLocalization.text("ISSN（可选，比刊名更准确）"), text: $journalISSN)

                            HStack(spacing: 10) {
                                SecureField("EasyScholar Secret Key", text: $secretKey)
                                Button(AppLocalization.text("保存密钥")) { saveSecretKey() }
                                    .disabled(secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button {
                                    NSWorkspace.shared.open(URL(string: "https://www.easyscholar.cc/user/open")!)
                                } label: {
                                    Label(AppLocalization.text("获取密钥"), systemImage: "safari")
                                }
                            }

                            HStack(spacing: 10) {
                                Button {
                                    lookupJournalMetrics()
                                } label: {
                                    if isLookingUp {
                                        ProgressView().controlSize(.small)
                                        Text(AppLocalization.text("正在检索…"))
                                    } else {
                                        Label(AppLocalization.text("自动检索期刊指标"), systemImage: "magnifyingglass")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isLookingUp || metricsQuery.isEmpty || secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                Text(journalISSN.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? AppLocalization.text("将使用期刊名称检索")
                                     : AppLocalization.text("将使用 ISSN 检索"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }

                            if let lookupMessage {
                                Label(lookupMessage, systemImage: lookupSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(lookupSucceeded ? Color.green : Color.red)
                            }

                            if let journalMetrics {
                                JournalMetricsPanel(snapshot: journalMetrics, compact: true)
                            }
                        }
                    }

                    EditorGroup(title: "索引与备注") {
                        TextField(AppLocalization.text("DOI、ISBN、专利号或其他编号"), text: $identifier)
                        TextField(AppLocalization.text("成果网页链接（可选）"), text: $url)
                        Text(AppLocalization.text("备注"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        NotesEditor(text: $notes, prompt: "记录贡献说明、奖项、引用信息或其他备注…")
                    }

                    if existingID == nil {
                        Label(AppLocalization.text("可以直接“保存并添加附件”，支持一次选择多个 PDF 或图片。"), systemImage: "paperclip")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                Spacer()
                Button(AppLocalization.text("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppLocalization.text("保存并添加附件")) { save(addAttachments: true) }
                    .disabled(!isValid || isLookingUp)
                Button(AppLocalization.text("保存")) { save(addAttachments: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid || isLookingUp)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 680, height: 720)
        .onDisappear { suggestionTask?.cancel() }
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save(addAttachments: Bool) {
        let key = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == .journalArticle,
           !key.isEmpty,
           !metricsQuery.isEmpty,
           journalMetrics?.query.caseInsensitiveCompare(metricsQuery) != .orderedSame {
            do {
                try EasyScholarSecretKeyStore.save(key)
            } catch {
                lookupSucceeded = false
                lookupMessage = AppLocalization.format("密钥保存失败：%@", error.localizedDescription)
                return
            }
            isLookingUp = true
            lookupMessage = AppLocalization.text("保存前正在自动检索期刊指标…")
            let query = metricsQuery
            Task {
                do {
                    let result = try await EasyScholarJournalMetricsService.lookup(query: query, secretKey: key)
                    await MainActor.run {
                        journalMetrics = result
                        isLookingUp = false
                        persistWork(addAttachments: addAttachments)
                    }
                } catch {
                    await MainActor.run {
                        isLookingUp = false
                        lookupSucceeded = false
                        lookupMessage = error.localizedDescription
                    }
                }
            }
            return
        }
        persistWork(addAttachments: addAttachments)
    }

    private func persistWork(addAttachments: Bool) {
        let id = store.saveExistingWork(
            existingID: existingID,
            title: title,
            type: type,
            venue: venue,
            authors: authors,
            completedAt: completedAt,
            identifier: identifier,
            url: normalizedURL(url),
            notes: notes,
            patentType: type == .patent ? patentType : nil,
            authorPosition: authorPosition,
            journalISSN: type == .journalArticle ? journalISSN : nil,
            journalMetrics: type == .journalArticle ? journalMetrics : nil
        )
        if addAttachments { store.addAttachments(to: id) }
        dismiss()
    }

    private var metricsQuery: String {
        let issn = journalISSN.trimmingCharacters(in: .whitespacesAndNewlines)
        if !issn.isEmpty { return issn }
        return venue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleJournalSuggestions(for value: String) {
        if suppressSuggestionRefresh {
            suppressSuggestionRefresh = false
            return
        }
        suggestionTask?.cancel()
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard type == .journalArticle, query.count >= 2 else {
            journalSuggestions = []
            isLoadingSuggestions = false
            return
        }
        isLoadingSuggestions = true
        suggestionTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let suggestions = (try? await JournalSuggestionService.suggestions(for: query)) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run {
                journalSuggestions = suggestions
                isLoadingSuggestions = false
            }
        }
    }

    private func selectJournalSuggestion(_ suggestion: JournalSuggestion) {
        suggestionTask?.cancel()
        suppressSuggestionRefresh = true
        venue = suggestion.title
        if !suggestion.issn.isEmpty { journalISSN = suggestion.issn }
        journalSuggestions = []
        isLoadingSuggestions = false
        journalMetrics = nil
        if secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lookupSucceeded = false
            lookupMessage = AppLocalization.text("已选择期刊；填写 EasyScholar Secret Key 后可自动匹配分区")
        } else {
            lookupJournalMetrics()
        }
    }

    private func saveSecretKey() {
        do {
            try EasyScholarSecretKeyStore.save(secretKey)
            lookupSucceeded = true
            lookupMessage = AppLocalization.text("密钥已保存到 macOS 钥匙串")
        } catch {
            lookupSucceeded = false
            lookupMessage = AppLocalization.format("密钥保存失败：%@", error.localizedDescription)
        }
    }

    private func lookupJournalMetrics() {
        let query = metricsQuery
        let key = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try EasyScholarSecretKeyStore.save(key)
        } catch {
            lookupSucceeded = false
            lookupMessage = AppLocalization.format("密钥保存失败：%@", error.localizedDescription)
            return
        }
        isLookingUp = true
        lookupMessage = nil
        Task {
            do {
                let result = try await EasyScholarJournalMetricsService.lookup(query: query, secretKey: key)
                await MainActor.run {
                    journalMetrics = result
                    isLookingUp = false
                    lookupSucceeded = true
                    lookupMessage = AppLocalization.format("已更新 %d 项期刊指标", result.items.count)
                }
            } catch {
                await MainActor.run {
                    isLookingUp = false
                    lookupSucceeded = false
                    lookupMessage = error.localizedDescription
                }
            }
        }
    }
}

struct ExistingWorkDetailView: View {
    @EnvironmentObject private var store: PaperStore
    @Environment(\.dismiss) private var dismiss
    let workID: String

    @State private var editWork = false
    @State private var confirmDelete = false
    @State private var attachmentToDelete: WorkAttachment?
    @State private var previewAttachment: WorkAttachment?

    private var work: ExistingWork? { store.existingWorks.first { $0.id == workID } }

    var body: some View {
        Group {
            if let work {
                VStack(spacing: 0) {
                    HStack {
                        Text(AppLocalization.text("成果详情"))
                            .font(.headline)
                        Spacer()
                        Button(AppLocalization.text("完成")) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding()
                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: work.type.symbol)
                                    .font(.title2.weight(.medium))
                                    .foregroundStyle(AppTheme.teal)
                                    .frame(width: 48, height: 48)
                                    .background(AppTheme.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(work.type == .patent ? (work.patentType?.title ?? work.type.title) : work.type.title)
                                        .font(.caption.bold())
                                        .foregroundStyle(AppTheme.blue)
                                    Text(work.title)
                                        .font(.system(size: 25, weight: .bold))
                                    if !work.venue.isEmpty {
                                        Text(work.venue).foregroundStyle(.secondary)
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 11) {
                                DetailRow(label: "完成日期", value: Formatters.longDate.string(from: work.completedAt))
                                if let patentType = work.patentType, work.type == .patent {
                                    DetailRow(label: "专利类型", value: patentType.title)
                                }
                                if !work.authors.isEmpty { DetailRow(label: "作者", value: work.authors) }
                                if let authorPosition = work.authorPosition {
                                    DetailRow(label: "我的署名", value: authorPosition.title)
                                }
                                if let journalISSN = work.journalISSN, !journalISSN.isEmpty, work.type == .journalArticle {
                                    DetailRow(label: "ISSN", value: journalISSN)
                                }
                                if !work.identifier.isEmpty { DetailRow(label: "DOI / 编号", value: work.identifier) }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))

                            if work.type == .journalArticle {
                                if let metrics = work.journalMetrics {
                                    JournalMetricsPanel(snapshot: metrics, compact: false)
                                } else {
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(AppLocalization.text("期刊评价")).font(.headline)
                                        Text(AppLocalization.text("尚未检索期刊收录、分区和影响因子。可通过“编辑成果”进行自动检索。"))
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            if !work.notes.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(AppLocalization.text("备注")).font(.headline)
                                    Text(work.notes).textSelection(.enabled)
                                }
                            }

                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(AppLocalization.text("附件")).font(.headline)
                                    Text("\(work.attachments.count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        store.addAttachments(to: work.id)
                                    } label: {
                                        Label(AppLocalization.text("添加 PDF 或图片"), systemImage: "paperclip")
                                    }
                                }

                                if work.attachments.isEmpty {
                                    Text(AppLocalization.text("还没有附件。"))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 8)
                                } else {
                                    ForEach(work.attachments) { attachment in
                                        HStack(spacing: 11) {
                                            Button {
                                                previewAttachment = attachment
                                            } label: {
                                                HStack(spacing: 11) {
                                                    Image(systemName: attachment.symbol)
                                                        .foregroundStyle(attachment.kind == "pdf" ? Color.red : AppTheme.blue)
                                                        .frame(width: 24)
                                                        .accessibilityHidden(true)
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(attachment.originalName)
                                                            .foregroundStyle(.primary)
                                                            .lineLimit(1)
                                                        Text(AppLocalization.format("添加于 %@", Formatters.dateTime.string(from: attachment.addedAt)))
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                    Spacer()
                                                    Image(systemName: "eye")
                                                        .foregroundStyle(.tertiary)
                                                        .accessibilityHidden(true)
                                                }
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityHint(AppLocalization.text("打开预览"))

                                            Button {
                                                store.openAttachment(attachment, for: work)
                                            } label: {
                                                Image(systemName: "arrow.up.right.square")
                                            }
                                            .buttonStyle(.borderless)
                                            .accessibilityLabel(AppLocalization.text("用默认应用打开"))
                                            .help(AppLocalization.text("用默认应用打开"))

                                            Button {
                                                NSWorkspace.shared.activateFileViewerSelecting([
                                                    store.attachmentURL(attachment, for: work),
                                                ])
                                            } label: {
                                                Image(systemName: "folder")
                                            }
                                            .buttonStyle(.borderless)
                                            .accessibilityLabel(AppLocalization.text("在访达中显示"))
                                            .help(AppLocalization.text("在访达中显示"))

                                            Button(role: .destructive) {
                                                attachmentToDelete = attachment
                                            } label: {
                                                Image(systemName: "trash")
                                            }
                                            .buttonStyle(.borderless)
                                            .accessibilityLabel(AppLocalization.text("删除附件"))
                                            .help(AppLocalization.text("删除附件"))
                                        }
                                        .padding(11)
                                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                                    }
                                }
                            }

                            Divider()
                            HStack {
                                Button {
                                    editWork = true
                                } label: {
                                    Label(AppLocalization.text("编辑成果"), systemImage: "square.and.pencil")
                                }
                                .buttonStyle(.borderedProminent)
                                if !work.url.isEmpty {
                                    Button {
                                        if let url = URL(string: work.url) { NSWorkspace.shared.open(url) }
                                    } label: {
                                        Label(AppLocalization.text("打开成果网页"), systemImage: "safari")
                                    }
                                }
                                Spacer()
                                Button(AppLocalization.text("删除成果"), role: .destructive) { confirmDelete = true }
                            }
                        }
                        .padding(28)
                    }
                }
            } else {
                Text(AppLocalization.text("该成果已被删除。")).padding(40)
            }
        }
        .frame(minWidth: 700, minHeight: 650)
        .sheet(isPresented: $editWork) {
            ExistingWorkEditor(work: work)
                .environmentObject(store)
        }
        .sheet(item: $previewAttachment) { attachment in
            if let work {
                QuickLookPreviewSheet(
                    url: store.attachmentURL(attachment, for: work),
                    title: attachment.originalName
                )
            }
        }
        .alert(AppLocalization.text("删除该成果及其附件？"), isPresented: $confirmDelete) {
            Button(AppLocalization.text("取消"), role: .cancel) {}
            Button(AppLocalization.text("删除"), role: .destructive) {
                if let work { store.deleteExistingWork(work) }
                dismiss()
            }
        } message: {
            Text(AppLocalization.text("成果记录及附件副本会移入回收站，可在30天内恢复。"))
        }
        .confirmationDialog(
            AppLocalization.text("删除该附件副本？"),
            isPresented: Binding(
                get: { attachmentToDelete != nil },
                set: { if !$0 { attachmentToDelete = nil } }
            )
        ) {
            Button(AppLocalization.text("删除附件"), role: .destructive) {
                if let attachmentToDelete { store.deleteAttachment(attachmentToDelete, from: workID) }
                attachmentToDelete = nil
            }
            Button(AppLocalization.text("取消"), role: .cancel) { attachmentToDelete = nil }
        }
    }
}

private struct JournalMetricsPanel: View {
    let snapshot: JournalMetricsSnapshot
    let compact: Bool

    private let columns = [
        GridItem(.flexible(), spacing: 9),
        GridItem(.flexible(), spacing: 9),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if !compact {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppLocalization.text("期刊评价"))
                            .font(.headline)
                        Text(snapshot.matchedJournalName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("EasyScholar · \(Formatters.shortDate.string(from: snapshot.lookedUpAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(JournalMetricGroup.allCases, id: \.rawValue) { group in
                let items = snapshot.items(in: group)
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
                            ForEach(items) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(item.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 5)
                                    Text(item.value)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.trailing)
                                        .textSelection(.enabled)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }
        }
        .padding(compact ? 12 : 16)
        .background(AppTheme.blue.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(AppTheme.blue.opacity(0.12)))
    }
}

private struct EditorGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(AppLocalization.text(title))
                .font(.headline)
            content
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.07)))
    }
}

private struct NotesEditor: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(AppLocalization.text(prompt))
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .padding(3)
        }
        .frame(height: 92)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.14)))
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(AppLocalization.text(label))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private func editorHeader(title: String, subtitle: String) -> some View {
    VStack(spacing: 0) {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.text(title)).font(.title2.weight(.semibold))
                Text(AppLocalization.text(subtitle)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        Divider()
    }
}

private func normalizedURL(_ input: String) -> String {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return "" }
    if value.contains("://") { return value }
    return "https://\(value)"
}
