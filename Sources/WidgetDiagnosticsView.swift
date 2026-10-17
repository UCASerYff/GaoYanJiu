import SwiftUI

/// Inspecting this view never acknowledges a WidgetKit read or changes data.
struct ResearchWidgetDiagnosticsView: View {
    @EnvironmentObject private var store: PaperStore
    @State private var report: [String: Any] = [:]

    private var snapshot: [String: Any] { report["snapshot"] as? [String: Any] ?? [:] }
    private var library: [String: Any] { report["library"] as? [String: Any] ?? [:] }
    private var provider: [String: Any] { report["widgetLastRead"] as? [String: Any] ?? [:] }
    private var timeline: [String: Any] { report["widgetLastTimelineRead"] as? [String: Any] ?? [:] }
    private var readStatus: [String: Any] { report["widgetReadStatus"] as? [String: Any] ?? [:] }
    private var publication: [String: Any] { report["exportStatus"] as? [String: Any] ?? [:] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(AppLocalization.text("资料库写入"), value: date(library["modifiedAt"]))
            LabeledContent(AppLocalization.text("统计内容更新"), value: date(snapshot["dataChangedAt"]))
            LabeledContent(AppLocalization.text("快照发布"), value: date(snapshot["generatedAt"]))
            LabeledContent(AppLocalization.text("组件最近成功读取"), value: date(provider["requestedAt"]))
            LabeledContent(AppLocalization.text("时间线最近成功读取"), value: date(timeline["requestedAt"]))
            if report["businessValuesMatch"] as? Bool == true {
                Text(AppLocalization.text("资料库与小组件快照的统计值一致。"))
            } else {
                Text(AppLocalization.text("尚未确认资料库与快照一致，请检查资料库读取或发布状态。"))
                    .foregroundStyle(.orange)
            }
            if publication["pending"] as? Bool == true {
                Text(AppLocalization.text("快照发布待重试，继续保留最后有效内容。"))
                    .foregroundStyle(.orange)
            }
            if readStatus["source"] as? String == "unavailable" {
                Text(AppLocalization.text("组件最近一次读取失败；上方保留最近成功读取的记录。"))
                    .foregroundStyle(.orange)
            } else if provider["source"] as? String == "last-good" {
                Text(AppLocalization.text("组件正在使用最后有效快照；当前快照读取失败。"))
                    .foregroundStyle(.orange)
            }
            Text(AppLocalization.text("统计时间来自可核验的快照或资料库写入，不能还原更早的业务编辑时刻。组件读取也不代表桌面已显示；刷新由系统调度。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(AppLocalization.text("重新读取状态"), action: inspect)
                Button(AppLocalization.text("重新发布快照")) {
                    store.exportWidgetSnapshot(reason: .activation)
                    inspect()
                }
                .disabled(store.libraryLoadFailed)
            }
        }
        .font(.callout)
        .onAppear(perform: inspect)
    }

    private func inspect() {
        report = (try? JSONSerialization.jsonObject(with: ResearchWidgetMaintenance.diagnostics())) as? [String: Any] ?? [:]
    }
    private func date(_ value: Any?) -> String {
        guard let value = value as? String else { return AppLocalization.text("尚无记录") }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let parsed = parser.date(from: value) else { return AppLocalization.text("尚无记录") }
        return parsed.formatted(date: .abbreviated, time: .standard)
    }
}
