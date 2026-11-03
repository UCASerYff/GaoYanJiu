import SwiftUI

/// Original funding is a read-only migration source; Savings owns editing.
struct FundingDashboard: View {
    @EnvironmentObject private var store: PaperStore
    let records: [FundingRecord]
    let allRecords: [FundingRecord]
    let isSearching: Bool

    private func openSavings(recordID: String? = nil) {
        ResearchFundingHandoffClient.open(recordID: recordID) { error in
            if let error { store.lastError = error }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label(AppLocalization.text("科研资金在搞积蓄管理"), systemImage: "banknote")
                    .font(.title3.weight(.semibold))
                Text(AppLocalization.text(ResearchFundingHandoff.readOnlyMessage))
                    .foregroundStyle(.secondary)
                Text(AppLocalization.text("以下是研究保留的原始计划，不代表已经到账，也不计入个人余额。实际迁移状态请在搞积蓄核对。"))
                    .font(.callout).foregroundStyle(.secondary)
                Button(AppLocalization.text("在搞积蓄管理")) { openSavings() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Text(AppLocalization.text("原资金记录（只读）")).font(.headline)
                Spacer()
                Text(AppLocalization.format("共 %d 条", allRecords.count)).foregroundStyle(.secondary)
            }
            if records.isEmpty {
                ListEmptyStateView(icon: "banknote",
                                   title: AppLocalization.text(isSearching ? "没有找到匹配的资金记录" : "还没有资金记录"),
                                   subtitle: AppLocalization.text("原记录保留在研究，新增与后续管理请使用搞积蓄。"),
                                   buttonTitle: nil, buttonAction: nil, embedded: true)
            } else {
                Table(records) {
                    TableColumn(AppLocalization.text("资金名称")) { record in
                        Button(record.name) { openSavings(recordID: record.id) }.buttonStyle(.link)
                    }.width(min: 130, ideal: 220)
                    TableColumn(AppLocalization.text("计划金额")) { record in
                        Text(record.amount, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                    }.width(min: 90, ideal: 115)
                    TableColumn(AppLocalization.text("适用年份")) { record in Text(String(record.year)) }
                        .width(min: 70, ideal: 90)
                    TableColumn(AppLocalization.text("发放周期")) { record in
                        Text(record.months.sorted().map(String.init).joined(separator: ", "))
                    }.width(min: 120, ideal: 200)
                    TableColumn(AppLocalization.text("收款账户"), value: \.receivingAccount)
                        .width(min: 120, ideal: 200)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }
}
