import AppKit
import Charts
import SwiftUI

struct CertificateYearCount: Identifiable, Equatable {
    let year: Int
    let count: Int
    var id: Int { year }
}

struct CertificateTagCount: Identifiable, Equatable {
    let tag: String
    let count: Int
    var id: String { tag }
}

enum CertificateAnalyticsData {
    static func yearCounts(for records: [CertificateRecord]) -> [CertificateYearCount] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let counts = Dictionary(grouping: records) {
            calendar.component(.year, from: $0.eventDate)
        }
        return counts.map { CertificateYearCount(year: $0.key, count: $0.value.count) }
            .sorted { $0.year < $1.year }
    }

    static func tagCounts(for records: [CertificateRecord], limit: Int = 8) -> [CertificateTagCount] {
        var counts: [String: Int] = [:]
        for record in records {
            let cleaned = Set(record.tags.compactMap { tag -> String? in
                let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            })
            if cleaned.isEmpty {
                counts[AppLocalization.text("未设置"), default: 0] += 1
            } else {
                for tag in cleaned { counts[tag, default: 0] += 1 }
            }
        }
        return counts.map { CertificateTagCount(tag: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending
            }
            .prefix(max(1, limit))
            .map { $0 }
    }
}

struct CertificateDashboard: View {
    @EnvironmentObject private var store: PaperStore
    let records: [CertificateRecord]
    let isSearching: Bool
    let openAction: (CertificateRecord) -> Void
    let createAction: () -> Void
    @State private var sortOrder: [KeyPathComparator<CertificateRecord>] = [
        KeyPathComparator(\CertificateRecord.eventDate, order: .reverse)
    ]
    @State private var editingRecord: CertificateRecord?
    @State private var recordPendingDeletion: CertificateRecord?

    private var sortedRecords: [CertificateRecord] {
        records.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
        if records.isEmpty {
            ListEmptyStateView(
                icon: "rectangle.badge.checkmark",
                title: AppLocalization.text(isSearching ? "没有找到匹配的证书记录" : "还没有证书记录"),
                subtitle: AppLocalization.text(isSearching
                     ? "试试使用其他名称、标签或附件名称。"
                     : "添加证书、获奖、竞赛、文体或任职记录，并统一保管 PDF 和图片附件。"),
                buttonTitle: isSearching ? nil : AppLocalization.text("新建证书记录"),
                buttonAction: isSearching ? nil : createAction
            )
        } else {
            VStack(spacing: 18) {
                CertificateAnalytics(records: records)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppLocalization.text("证书记录表"))
                                .font(.headline)
                            Text(AppLocalization.text("按名称、时间、标签和附件四个维度统一管理"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(AppLocalization.format("共 %d 条", records.count))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Table(sortedRecords, sortOrder: $sortOrder) {
                        TableColumn(AppLocalization.text("名称"), value: \.name) { record in
                            Button(record.name) { openAction(record) }
                                .buttonStyle(.plain)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(AppTheme.blue)
                                .lineLimit(2)
                                .contextMenu { rowContextMenu(for: record) }
                                .listHoverHighlight(cornerRadius: 6)
                        }
                        .width(min: 190, ideal: 300)

                        TableColumn(AppLocalization.text("时间"), value: \.eventDate) { record in
                            Text(Formatters.longDate.string(from: record.eventDate))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .contextMenu { rowContextMenu(for: record) }
                                .listHoverHighlight(cornerRadius: 6)
                        }
                        .width(min: 120, ideal: 150)

                        TableColumn(AppLocalization.text("标签"), value: \.sortableTags) { record in
                            if record.tags.isEmpty {
                                Text(AppLocalization.text("未设置"))
                                    .foregroundStyle(.tertiary)
                                    .contextMenu { rowContextMenu(for: record) }
                                    .listHoverHighlight(cornerRadius: 6)
                                .listHoverHighlight(cornerRadius: 6)
                            } else {
                                HStack(spacing: 5) {
                                    ForEach(Array(record.tags.prefix(3)), id: \.self) { tag in
                                        CertificateTagBadge(tag: tag, compact: true)
                                    }
                                    if record.tags.count > 3 {
                                        Text("+\(record.tags.count - 3)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .lineLimit(1)
                                .contextMenu { rowContextMenu(for: record) }
                                .listHoverHighlight(cornerRadius: 6)
                            }
                        }
                        .width(min: 190, ideal: 280)

                        TableColumn(AppLocalization.text("附件")) { record in
                            Button {
                                openAction(record)
                            } label: {
                                Label("\(record.attachments.count)", systemImage: record.attachments.isEmpty ? "paperclip" : "paperclip.circle.fill")
                                    .font(.callout.monospacedDigit())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(record.attachments.isEmpty ? Color.secondary : AppTheme.teal)
                            .accessibilityLabel(AppLocalization.format("%d 个附件", record.attachments.count))
                            .contextMenu { rowContextMenu(for: record) }
                        }
                        .width(min: 80, ideal: 100)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: true))
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        }
        .sheet(item: $editingRecord) { record in
            CertificateEditor(record: record)
                .environmentObject(store)
        }
        .alert(
            AppLocalization.text("删除该证书记录及其附件？"),
            isPresented: Binding(
                get: { recordPendingDeletion != nil },
                set: { if !$0 { recordPendingDeletion = nil } }
            )
        ) {
            Button(AppLocalization.text("取消"), role: .cancel) {}
            Button(AppLocalization.text("删除"), role: .destructive) {
                if let record = recordPendingDeletion { store.deleteCertificate(record) }
                recordPendingDeletion = nil
            }
        } message: {
            Text(AppLocalization.text("证书记录及附件副本会移入回收站，可在30天内恢复。"))
        }
    }

    @ViewBuilder
    private func rowContextMenu(for record: CertificateRecord) -> some View {
        Button {
            openAction(record)
        } label: {
            Label(AppLocalization.text("查看详情"), systemImage: "doc.text.magnifyingglass")
        }
        Button {
            editingRecord = record
        } label: {
            Label(AppLocalization.text("编辑"), systemImage: "square.and.pencil")
        }
        Divider()
        Button(role: .destructive) {
            recordPendingDeletion = record
        } label: {
            Label(AppLocalization.text("删除"), systemImage: "trash")
        }
    }
}

private struct CertificateAnalytics: View {
    let records: [CertificateRecord]

    private var yearData: [CertificateYearCount] {
        CertificateAnalyticsData.yearCounts(for: records)
    }

    private var tagData: [CertificateTagCount] {
        CertificateAnalyticsData.tagCounts(for: records)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            analyticsCard(
                title: "证书年度趋势",
                subtitle: "按证书时间统计当前列表中的年度数量"
            ) {
                Chart(yearData) { item in
                    BarMark(
                        x: .value(AppLocalization.text("年份"), String(item.year)),
                        y: .value(AppLocalization.text("数量"), item.count)
                    )
                    .foregroundStyle(AppTheme.blue.opacity(0.16))
                    .cornerRadius(5)

                    LineMark(
                        x: .value(AppLocalization.text("年份"), String(item.year)),
                        y: .value(AppLocalization.text("数量"), item.count)
                    )
                    .foregroundStyle(AppTheme.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))

                    PointMark(
                        x: .value(AppLocalization.text("年份"), String(item.year)),
                        y: .value(AppLocalization.text("数量"), item.count)
                    )
                    .foregroundStyle(AppTheme.blue)
                    .annotation(position: .top) {
                        Text("\(item.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel()
                    }
                }
                .frame(height: 190)
                .accessibilityChartDescriptor(ChartAccessibility.descriptor(
                    title: AppLocalization.text("证书年度趋势"),
                    summary: AppLocalization.format(
                        "覆盖 %d 个年份，合计 %d 条证书记录",
                        yearData.count,
                        yearData.reduce(0) { $0 + $1.count }
                    ),
                    categoryAxisTitle: AppLocalization.text("年份"),
                    valueAxisTitle: AppLocalization.text("数量"),
                    points: yearData.map { (category: String($0.year), value: Double($0.count)) },
                    valueDescription: { AppLocalization.format("%d 条", Int($0)) }
                ))
            }

            analyticsCard(
                title: "证书标签分布",
                subtitle: "按当前列表统计，显示数量最多的 8 个标签"
            ) {
                CertificateTagBars(items: tagData)
                    .frame(height: 190)
            }
        }
    }

    private func analyticsCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.text(title))
                    .font(.headline)
                Text(AppLocalization.text(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
}

private struct CertificateTagBars: View {
    let items: [CertificateTagCount]

    private var maximum: CGFloat {
        CGFloat(max(items.map(\.count).max() ?? 1, 1))
    }

    var body: some View {
        VStack(spacing: 7) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Text(item.tag)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 92, alignment: .trailing)
                        .help(item.tag)

                    GeometryReader { proxy in
                        let ratio = CGFloat(item.count) / maximum
                        RoundedRectangle(cornerRadius: 4)
                            .fill(CertificateTagColor.color(for: item.tag))
                            .frame(width: max(4, proxy.size.width * ratio))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 14)
                    .accessibilityHidden(true)

                    Text("\(item.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
    }
}

private extension CertificateRecord {
    var sortableTags: String {
        tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .joined(separator: " · ")
    }
}

private enum CertificateTagColor {
    private static let palette: [Color] = [
        AppTheme.blue, AppTheme.teal, .orange, .purple, .pink, .green, .indigo, .red,
    ]

    static func color(for tag: String) -> Color {
        var value: UInt64 = 14_695_981_039_346_656_037
        for scalar in tag.unicodeScalars {
            value ^= UInt64(scalar.value)
            value &*= 1_099_511_628_211
        }
        return palette[Int(value % UInt64(palette.count))]
    }
}

private struct CertificateTagBadge: View {
    let tag: String
    var compact = false

    var body: some View {
        let color = CertificateTagColor.color(for: tag)
        Text(tag)
            .font(compact ? .caption2.weight(.medium) : .caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, compact ? 3 : 5)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.18)))
    }
}

struct CertificateEditor: View {
    @EnvironmentObject private var store: PaperStore
    @Environment(\.dismiss) private var dismiss

    private let existingID: String?
    @State private var name: String
    @State private var eventDate: Date
    @State private var tags: [String]

    init(record: CertificateRecord?) {
        existingID = record?.id
        _name = State(initialValue: record?.name ?? "")
        _eventDate = State(initialValue: record?.eventDate ?? Date())
        _tags = State(initialValue: record?.tags ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            CertificateEditorHeader(
                title: existingID == nil ? "新建证书记录" : "编辑证书记录",
                subtitle: "填写名称和时间，并添加任意自定义标签。"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    CertificateEditorGroup(title: "基本信息") {
                        TextField(AppLocalization.text("名称（必填）"), text: $name)
                        DatePicker(AppLocalization.text("时间"), selection: $eventDate, displayedComponents: [.date])
                            .datePickerStyle(.field)
                    }

                    CertificateEditorGroup(title: "标签") {
                        CertificateTagEditor(tags: $tags)
                    }

                    CertificateEditorGroup(title: "附件") {
                        Label(AppLocalization.text("支持同时上传多个 PDF 和图片。附件会复制到应用资料目录中统一保管。"), systemImage: "paperclip")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if existingID == nil {
                            Text(AppLocalization.text("首次保存时可直接选择“保存并添加附件”。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                    .disabled(!isValid)
                Button(AppLocalization.text("保存")) { save(addAttachments: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 680, height: 650)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save(addAttachments: Bool) {
        let id = store.saveCertificate(
            existingID: existingID,
            name: name,
            eventDate: eventDate,
            tags: tags
        )
        if addAttachments { store.addCertificateAttachments(to: id) }
        dismiss()
    }
}

private struct CertificateTagEditor: View {
    @Binding var tags: [String]
    @State private var newTag = ""

    private let suggestions = ["竞赛", "文体", "任职", "荣誉", "培训", "资质"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if tags.isEmpty {
                Text(AppLocalization.text("还没有标签，可使用快捷标签或输入自定义标签。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 7) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            tags.removeAll { $0 == tag }
                        } label: {
                            let color = CertificateTagColor.color(for: tag)
                            HStack(spacing: 5) {
                                Text(tag)
                                Image(systemName: "xmark")
                                    .font(.caption2.bold())
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(color.opacity(0.12), in: Capsule())
                            .overlay(Capsule().stroke(color.opacity(0.18)))
                            .foregroundStyle(color)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AppLocalization.format("移除标签 %@", tag))
                        .help(AppLocalization.text("移除标签"))
                    }
                }
            }

            HStack(spacing: 9) {
                TextField(AppLocalization.text("输入自定义标签，可用逗号分隔"), text: $newTag)
                    .onSubmit(addCustomTags)
                Button(AppLocalization.text("添加")) { addCustomTags() }
                    .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Menu(AppLocalization.text("快捷标签")) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) { addTag(suggestion) }
                    }
                }
            }
        }
    }

    private func addCustomTags() {
        let separators = CharacterSet(charactersIn: ",，、;；")
        newTag.components(separatedBy: separators).forEach(addTag)
        newTag = ""
    }

    private func addTag(_ input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !tags.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        tags.append(value)
    }
}

struct CertificateDetailView: View {
    @EnvironmentObject private var store: PaperStore
    @Environment(\.dismiss) private var dismiss
    let recordID: String

    @State private var editRecord = false
    @State private var confirmDelete = false
    @State private var attachmentToDelete: WorkAttachment?
    @State private var previewAttachment: WorkAttachment?

    private var record: CertificateRecord? { store.certificates.first { $0.id == recordID } }

    var body: some View {
        Group {
            if let record {
                VStack(spacing: 0) {
                    HStack {
                        Text(AppLocalization.text("证书记录详情"))
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
                                Image(systemName: "rectangle.badge.checkmark")
                                    .font(.title2.weight(.medium))
                                    .foregroundStyle(AppTheme.blue)
                                    .frame(width: 48, height: 48)
                                    .background(AppTheme.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(AppLocalization.text("证书记录"))
                                        .font(.caption.bold())
                                        .foregroundStyle(AppTheme.blue)
                                    Text(record.name)
                                        .font(.system(size: 25, weight: .bold))
                                    Text(Formatters.longDate.string(from: record.eventDate))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Text(AppLocalization.text("标签"))
                                    .font(.headline)
                                if record.tags.isEmpty {
                                    Text(AppLocalization.text("未设置标签"))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                } else {
                                    FlowLayout(spacing: 7) {
                                        ForEach(record.tags, id: \.self) { tag in
                                            CertificateTagBadge(tag: tag)
                                        }
                                    }
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))

                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(AppLocalization.text("附件"))
                                        .font(.headline)
                                    Text("\(record.attachments.count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        store.addCertificateAttachments(to: record.id)
                                    } label: {
                                        Label(AppLocalization.text("添加 PDF 或图片"), systemImage: "paperclip")
                                    }
                                }

                                if record.attachments.isEmpty {
                                    Text(AppLocalization.text("还没有附件。"))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 8)
                                } else {
                                    ForEach(record.attachments) { attachment in
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
                                                store.openCertificateAttachment(attachment, for: record)
                                            } label: {
                                                Image(systemName: "arrow.up.right.square")
                                            }
                                            .buttonStyle(.borderless)
                                            .accessibilityLabel(AppLocalization.text("用默认应用打开"))
                                            .help(AppLocalization.text("用默认应用打开"))

                                            Button {
                                                NSWorkspace.shared.activateFileViewerSelecting([
                                                    store.certificateAttachmentURL(attachment, for: record),
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
                                    editRecord = true
                                } label: {
                                    Label(AppLocalization.text("编辑记录"), systemImage: "square.and.pencil")
                                }
                                .buttonStyle(.borderedProminent)
                                Spacer()
                                Button(AppLocalization.text("删除记录"), role: .destructive) { confirmDelete = true }
                            }
                        }
                        .padding(28)
                    }
                }
            } else {
                Text(AppLocalization.text("该证书记录已被删除。"))
                    .padding(40)
            }
        }
        .frame(minWidth: 700, minHeight: 650)
        .sheet(isPresented: $editRecord) {
            CertificateEditor(record: record)
                .environmentObject(store)
        }
        .sheet(item: $previewAttachment) { attachment in
            if let record {
                QuickLookPreviewSheet(
                    url: store.certificateAttachmentURL(attachment, for: record),
                    title: attachment.originalName
                )
            }
        }
        .alert(AppLocalization.text("删除该证书记录及其附件？"), isPresented: $confirmDelete) {
            Button(AppLocalization.text("取消"), role: .cancel) {}
            Button(AppLocalization.text("删除"), role: .destructive) {
                if let record { store.deleteCertificate(record) }
                dismiss()
            }
        } message: {
            Text(AppLocalization.text("证书记录及附件副本会移入回收站，可在30天内恢复。"))
        }
        .confirmationDialog(
            AppLocalization.text("删除该附件副本？"),
            isPresented: Binding(
                get: { attachmentToDelete != nil },
                set: { if !$0 { attachmentToDelete = nil } }
            )
        ) {
            Button(AppLocalization.text("删除附件"), role: .destructive) {
                if let attachmentToDelete {
                    store.deleteCertificateAttachment(attachmentToDelete, from: recordID)
                }
                attachmentToDelete = nil
            }
            Button(AppLocalization.text("取消"), role: .cancel) { attachmentToDelete = nil }
        }
    }
}

private struct CertificateEditorGroup<Content: View>: View {
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

private struct CertificateEditorHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.text(title))
                        .font(.title2.weight(.semibold))
                    Text(AppLocalization.text(subtitle))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()
        }
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let availableWidth = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > availableWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return (CGSize(width: proposal.width ?? x, height: y + rowHeight), points)
    }
}
