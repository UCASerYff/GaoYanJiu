import AppKit
import SwiftUI

struct FundingDashboard: View {
    @EnvironmentObject private var store: PaperStore
    let records: [FundingRecord]
    let allRecords: [FundingRecord]
    let isSearching: Bool
    let openAction: (FundingRecord) -> Void
    let createAction: () -> Void
    @State private var sortOrder: [KeyPathComparator<FundingRecord>] = [
        KeyPathComparator(\FundingRecord.year, order: .reverse)
    ]
    @State private var recordPendingDeletion: FundingRecord?

    private var sortedRecords: [FundingRecord] {
        records.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 16) {
            FundingMonthlyOverview(records: allRecords)

            if records.isEmpty {
                // 外层 VStack 已自带水平/底部 padding，空状态用 embedded 模式省略重复留白。
                ListEmptyStateView(
                    icon: "banknote",
                    title: AppLocalization.text(isSearching ? "没有找到匹配的资金记录" : "还没有资金记录"),
                    subtitle: AppLocalization.text(isSearching
                         ? "试试搜索其他资金名称、年份或收款账户。"
                         : "分别建立工资、津贴、项目经费等组成部分，并勾选每年实际发放的月份。"),
                    buttonTitle: isSearching ? nil : AppLocalization.text("新建资金记录"),
                    buttonAction: isSearching ? nil : createAction,
                    embedded: true
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppLocalization.text("资金明细表"))
                                .font(.headline)
                            Text(AppLocalization.text("按年份和月份维护每一项资金的发放安排"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(AppLocalization.format("共 %d 条", records.count))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Table(sortedRecords, sortOrder: $sortOrder) {
                        TableColumn(AppLocalization.text("资金名称"), value: \.name) { record in
                            Button(record.name) { openAction(record) }
                                .buttonStyle(.plain)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(AppTheme.blue)
                                .lineLimit(2)
                                .contextMenu { rowContextMenu(for: record) }
                                .listHoverHighlight(cornerRadius: 6)
                        }
                        .width(min: 150, ideal: 230)

                        TableColumn(AppLocalization.text("金额"), value: \.amount) { record in
                            Text(FundingFormatters.currency(record.amount))
                                .font(.callout.weight(.medium).monospacedDigit())
                                .contextMenu { rowContextMenu(for: record) }
                                .listHoverHighlight(cornerRadius: 6)
                        }
                        .width(min: 100, ideal: 125)

                        TableColumn(AppLocalization.text("适用年份"), value: \.year) { record in
                            Text(AppLocalization.format("%d年", record.year))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .contextMenu { rowContextMenu(for: record) }
                                .listHoverHighlight(cornerRadius: 6)
                        }
                        .width(min: 80, ideal: 95)

                        TableColumn(AppLocalization.text("发放周期")) { record in
                            Text(fundingMonthsDescription(record.months))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .help(record.months.sorted().map { AppLocalization.format("%d月", $0) }.joined(separator: AppLocalization.text("、")))
                                .contextMenu { rowContextMenu(for: record) }
                                .listHoverHighlight(cornerRadius: 6)
                        }
                        .width(min: 160, ideal: 230)

                        TableColumn(AppLocalization.text("收款账户"), value: \.receivingAccount) { record in
                            Text(record.receivingAccount)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .contextMenu { rowContextMenu(for: record) }
                                .listHoverHighlight(cornerRadius: 6)
                        }
                        .width(min: 150, ideal: 220)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: true))
                }
                .padding(16)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .alert(
            AppLocalization.text("删除该资金记录？"),
            isPresented: Binding(
                get: { recordPendingDeletion != nil },
                set: { if !$0 { recordPendingDeletion = nil } }
            )
        ) {
            Button(AppLocalization.text("取消"), role: .cancel) {}
            Button(AppLocalization.text("删除"), role: .destructive) {
                if let record = recordPendingDeletion { store.deleteFundingRecord(record) }
                recordPendingDeletion = nil
            }
        } message: {
            Text(AppLocalization.text("删除后将不再计入月份汇总，但可在回收站中恢复。"))
        }
    }

    @ViewBuilder
    private func rowContextMenu(for record: FundingRecord) -> some View {
        Button {
            openAction(record)
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

private struct FundingMonthSnapshot: Identifiable {
    let id: Int
    let label: String
    let date: Date
    let total: Double
    let itemCount: Int
}

private struct FundingMonthlyOverview: View {
    let records: [FundingRecord]

    private var snapshots: [FundingMonthSnapshot] {
        let calendar = Calendar.current
        return [(-1, AppLocalization.text("上个月")), (0, AppLocalization.text("本月")), (1, AppLocalization.text("下个月"))].compactMap { offset, label in
            guard let date = calendar.date(byAdding: .month, value: offset, to: Date()) else { return nil }
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else { return nil }
            let scheduled = records.filter { $0.isScheduled(year: year, month: month) }
            return FundingMonthSnapshot(
                id: offset,
                label: label,
                date: date,
                total: scheduled.reduce(0) { $0 + $1.amount },
                itemCount: scheduled.count
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.text("近期资金汇总"))
                        .font(.headline)
                    Text(AppLocalization.text("根据适用年份和已勾选月份自动计算"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                ForEach(snapshots) { snapshot in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(snapshot.label)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Text(FundingFormatters.month.string(from: snapshot.date))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(FundingFormatters.currency(snapshot.total))
                            .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(snapshot.id == 0 ? AppTheme.blue : Color.primary)
                        Text(AppLocalization.format("%d 项资金", snapshot.itemCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        snapshot.id == 0 ? AppTheme.blue.opacity(0.08) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 11)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(snapshot.id == 0 ? AppTheme.blue.opacity(0.2) : Color.primary.opacity(0.06))
                    )
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
}

struct FundingEditor: View {
    @EnvironmentObject private var store: PaperStore
    @Environment(\.dismiss) private var dismiss

    private let existingRecord: FundingRecord?
    @State private var name: String
    @State private var amountText: String
    @State private var year: Int
    @State private var selectedMonths: Set<Int>
    @State private var receivingAccount: String
    @State private var confirmDelete = false

    init(record: FundingRecord?) {
        existingRecord = record
        let currentYear = Calendar.current.component(.year, from: Date())
        _name = State(initialValue: record?.name ?? "")
        _amountText = State(initialValue: record.map { FundingFormatters.editableAmount($0.amount) } ?? "")
        _year = State(initialValue: record?.year ?? currentYear)
        _selectedMonths = State(initialValue: Set(record?.months ?? Array(1...12)))
        _receivingAccount = State(initialValue: record?.receivingAccount ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.text(existingRecord == nil ? "新建资金记录" : "编辑资金记录"))
                    .font(.title2.weight(.semibold))
                Text(AppLocalization.text("按年度设置金额、实际发放月份和收款账户。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FundingEditorGroup(title: "资金信息") {
                        TextField(AppLocalization.text("资金名称（必填）"), text: $name)
                        HStack {
                            Text(AppLocalization.text("金额"))
                            Spacer()
                            Text("¥")
                                .foregroundStyle(.secondary)
                            TextField("0.00", text: $amountText)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 180)
                        }
                        HStack {
                            Text(AppLocalization.text("适用年份"))
                            Spacer()
                            Stepper(value: $year, in: 2000...2100) {
                                Text(AppLocalization.format("%d年", year))
                            }
                                .fixedSize()
                        }
                    }

                    FundingEditorGroup(title: "发放周期") {
                        HStack {
                            Text(AppLocalization.format("勾选该资金在 %d 年实际发放的月份", year))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(AppLocalization.text("全选")) { selectedMonths = Set(1...12) }
                            Button(AppLocalization.text("清空")) { selectedMonths.removeAll() }
                        }

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 4), spacing: 9) {
                            ForEach(1...12, id: \.self) { month in
                                Button {
                                    if selectedMonths.contains(month) {
                                        selectedMonths.remove(month)
                                    } else {
                                        selectedMonths.insert(month)
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: selectedMonths.contains(month) ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(selectedMonths.contains(month) ? AppTheme.blue : Color.secondary)
                                            .accessibilityHidden(true)
                                        Text(AppLocalization.format("%d月", month))
                                            .font(.callout.monospacedDigit())
                                        Spacer()
                                    }
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 9)
                                    .background(
                                        selectedMonths.contains(month) ? AppTheme.blue.opacity(0.08) : Color.primary.opacity(0.025),
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selectedMonths.contains(month) ? [.isSelected] : [])
                            }
                        }
                    }

                    FundingEditorGroup(title: "收款账户") {
                        TextField(AppLocalization.text("例如：招商银行 · 尾号 1234"), text: $receivingAccount)
                        Text(AppLocalization.text("建议只记录银行名称和卡号末四位，不必填写完整卡号。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                if existingRecord != nil {
                    Button(AppLocalization.text("删除记录"), role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button(AppLocalization.text("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppLocalization.text("保存")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 680, height: 700)
        .alert(AppLocalization.text("删除该资金记录？"), isPresented: $confirmDelete) {
            Button(AppLocalization.text("取消"), role: .cancel) {}
            Button(AppLocalization.text("删除"), role: .destructive) {
                if let existingRecord { store.deleteFundingRecord(existingRecord) }
                dismiss()
            }
        } message: {
            Text(AppLocalization.text("删除后将不再计入月份汇总，但可在回收站中恢复。"))
        }
    }

    private var parsedAmount: Double? {
        let normalized = amountText
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (parsedAmount ?? 0) > 0
            && !selectedMonths.isEmpty
            && !receivingAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard let amount = parsedAmount else { return }
        store.saveFundingRecord(
            existingID: existingRecord?.id,
            name: name,
            amount: amount,
            year: year,
            months: Array(selectedMonths),
            receivingAccount: receivingAccount
        )
        dismiss()
    }
}

private struct FundingEditorGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppLocalization.text(title))
                .font(.headline)
            content
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.07)))
    }
}

private enum FundingFormatters {
    static var month: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLocalization.language.locale
        formatter.setLocalizedDateFormatFromTemplate("yMMM")
        return formatter
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.currencyCode = "CNY"
        formatter.currencySymbol = "¥"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let editorFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    static func currency(_ amount: Double) -> String {
        currencyFormatter.string(from: NSNumber(value: amount)) ?? String(format: "¥%.2f", amount)
    }

    static func editableAmount(_ amount: Double) -> String {
        editorFormatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }
}

private func fundingMonthsDescription(_ months: [Int]) -> String {
    let values = Array(Set(months.filter { (1...12).contains($0) })).sorted()
    guard !values.isEmpty else { return AppLocalization.text("未设置") }
    if values.count == 12 { return AppLocalization.text("全年") }

    var ranges: [(start: Int, end: Int)] = []
    for month in values {
        if let last = ranges.last, month == last.end + 1 {
            ranges[ranges.count - 1].end = month
        } else {
            ranges.append((month, month))
        }
    }

    return ranges.map { range in
        range.start == range.end
            ? AppLocalization.format("%d月", range.start)
            : AppLocalization.format("%d–%d月", range.start, range.end)
    }.joined(separator: AppLocalization.text("、"))
}
