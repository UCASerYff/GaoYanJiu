import SwiftUI
import WidgetKit

struct StatisticsEntry: TimelineEntry {
    let date: Date
    let snapshot: ResearchWidgetSnapshot?
    let readAt: Date?
    let readSource: String
    init(date: Date, snapshot: ResearchWidgetSnapshot?, readAt: Date? = nil, readSource: String = "unavailable") {
        self.date = date; self.snapshot = snapshot; self.readAt = readAt; self.readSource = readSource
    }
}
struct StatisticsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatisticsEntry { .init(date:Date(),snapshot:nil) }
    func getSnapshot(in context: Context, completion: @escaping (StatisticsEntry) -> Void) { completion(read(requestKind: "snapshot")) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StatisticsEntry>) -> Void) {
        let entry = read(requestKind: "timeline")
        // Daily entries keep elapsed days advancing while the main app is closed.
        let entries = ResearchWidgetSchedule.entryDates(from: entry.date).map { date in
            StatisticsEntry(date: date, snapshot: entry.snapshot, readAt: entry.readAt, readSource: entry.readSource)
        }
        completion(Timeline(entries: entries, policy: .after(ResearchWidgetSchedule.nextRefresh(after: entry.date))))
    }
    private func read(requestKind: String) -> StatisticsEntry {
        let value = ResearchWidgetStorage.read(at: ResearchWidgetSnapshot.fileURL, recordStatus: true, requestKind: requestKind)
        NSLog("Research widget read: request=%@ source=%@ schema=%d revision=%@ generatedAt=%@ readAt=%@", requestKind, value.source,
              value.snapshot?.schemaVersion ?? 0, value.snapshot?.revision ?? "legacy-or-unavailable",
              value.snapshot?.generatedAt.description ?? "unknown", value.readAt.description)
        return .init(date: value.readAt, snapshot: value.snapshot, readAt: value.snapshot == nil ? nil : value.readAt, readSource: value.source)
    }
}
// Each visible row receives its share of the available height. The minimum
// preserves a legible title and progress bar; there is no family-specific cap.
struct WidgetRowLayout {
    static let minimumPaperHeight: CGFloat = 22
    let count: Int
    let rowHeight: CGFloat
    init(height: CGFloat, itemCount: Int) {
        let available = height.isFinite ? max(0, height) : 0
        count = min(max(0, itemCount), Int(available / Self.minimumPaperHeight))
        rowHeight = count > 0 ? available / CGFloat(count) : 0
    }
}

struct StatisticsView: View {
    let entry: StatisticsEntry
    let submissions: Bool
    var body: some View {
        StatisticsContentView(entry: entry, submissions: submissions)
            // 点击小组件唤起主 App 并切换到对应模块（App 侧 onOpenURL 接收）
            .widgetURL(URL(string: submissions ? "gaoyanjiu://submissions" : "gaoyanjiu://works"))
            .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }
}

// Shared by the extension and the size/appearance rendering checks.
struct StatisticsContentView: View {
    let entry: StatisticsEntry
    let submissions: Bool

    static func newestPapers(_ papers: [ResearchWidgetSnapshot.Paper]) -> [ResearchWidgetSnapshot.Paper] {
        papers.sorted { a, b in a.since == b.since ? a.id < b.id : a.since > b.since }
    }

    var body: some View {
        if let snapshot = entry.snapshot {
            GeometryReader { geometry in
                let bodyHeight = max(0, geometry.size.height - 36)
                let layout = WidgetRowLayout(height: bodyHeight, itemCount: snapshot.papers.count)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(submissions ? (snapshot.english ? "Submission duration" : "在投状态持续时间") : (snapshot.english ? "Research achievements" : "成果与署名分布"))
                            .font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 4)
                        Text("\(submissions ? snapshot.papers.count : snapshot.totalWorks)")
                            .font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(.blue)
                    }.frame(height: 18)
                    Group {
                        if submissions { papers(snapshot, layout: layout) }
                        else { achievements(snapshot, height: bodyHeight) }
                    }.frame(height: bodyHeight)
                    HStack(spacing: 3) {
                        Text(statisticsDateLabel(snapshot))
                        Text(snapshot.dataChangedAt, style: .date)
                        Spacer(minLength: 2)
                        if let readAt = entry.readAt {
                            Text(entry.readSource == "last-good" ? (snapshot.english ? "Saved read" : "缓存读取") : (snapshot.english ? "Read" : "读取"))
                            Text(readAt, format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                        }
                        if submissions, layout.count < snapshot.papers.count {
                            Text(snapshot.english ? "Newest \(layout.count)/\(snapshot.papers.count)" : "最新 \(layout.count)/\(snapshot.papers.count) 篇")
                        }
                    }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.65).frame(height: 10)
                        .help(snapshot.english
                              ? "Statistics time is separate from snapshot generation and widget reading. Historical publication time does not prove the last business edit."
                              : "统计内容时间、快照生成和组件读取分别记录；历史发布时间不等于业务最后编辑时间。")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("搞研究").font(.headline)
                Text("请先打开搞研究，同步小组件数据。\nOpen the app to sync statistics.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func statisticsDateLabel(_ snapshot: ResearchWidgetSnapshot) -> String {
        if snapshot.dataChangedAtBasis == "legacy-publication" { return snapshot.english ? "Published" : "统计发布" }
        if snapshot.dataChangedAtBasis == "source-write-baseline" { return snapshot.english ? "Baseline" : "统计基准" }
        return snapshot.english ? "Stats" : "统计更新"
    }

    private func papers(_ snapshot: ResearchWidgetSnapshot, layout: WidgetRowLayout) -> some View {
        let sorted = Self.newestPapers(snapshot.papers)
        let maximum = max(1, sorted.map { $0.days(at: entry.date) }.max() ?? 0)
        return VStack(alignment: .leading, spacing: 0) {
            if sorted.isEmpty {
                Text(snapshot.english ? "No submissions" : "暂无在投论文")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ForEach(Array(sorted.prefix(layout.count))) { paper in
                let days = paper.days(at: entry.date)
                let color: Color = paper.terminal ? .gray : days >= 90 ? .red : days >= 60 ? .orange : .blue
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(paper.title)
                            .font(.system(size: layout.rowHeight >= 32 ? 12 : 11))
                            .lineLimit(layout.rowHeight >= 42 ? 2 : 1)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(color.opacity(0.12))
                                Capsule().fill(color).frame(width: days == 0 ? 0 : max(2, proxy.size.width * CGFloat(days) / CGFloat(maximum)))
                            }
                        }.frame(height: layout.rowHeight >= 42 ? 6 : 3)
                    }
                    Text(snapshot.english ? "\(days)d" : "\(days)天")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(color)
                        .fixedSize(horizontal: true, vertical: false)
                }.frame(height: layout.rowHeight)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func achievements(_ snapshot: ResearchWidgetSnapshot, height: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 12) {
            distribution(snapshot.categories, title: snapshot.english ? "Categories" : "成果类别", color: .blue, height: height)
            distribution(snapshot.authors, title: snapshot.english ? "Authorship" : "我的署名", color: .teal, height: height)
        }
    }

    private func distribution(_ items: [ResearchWidgetSnapshot.Count], title: String, color: Color, height: CGFloat) -> some View {
        let maximum = max(1, items.map(\.count).max() ?? 0)
        let rowHeight = max(0, height - 20) / CGFloat(max(1, items.count))
        return VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11, weight: .semibold)).frame(height: 20, alignment: .top)
            ForEach(items) { item in
                VStack(spacing: 3) {
                    HStack(spacing: 2) {
                        Text(item.label).lineLimit(1).minimumScaleFactor(0.65)
                        Spacer(minLength: 1)
                        Text("\(item.count)").monospacedDigit().fixedSize()
                    }.font(.system(size: rowHeight >= 30 ? 12 : 10))
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(color.opacity(0.12))
                            Capsule().fill(color).frame(width: proxy.size.width * CGFloat(item.count) / CGFloat(maximum))
                        }
                    }.frame(height: rowHeight >= 36 ? 6 : 3)
                }.frame(height: rowHeight)
            }
            if items.isEmpty {
                Text("—").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
struct SubmissionDurationWidget: Widget {
    let kind = "ResearchSubmissionDuration"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind:kind,provider:StatisticsProvider()) { StatisticsView(entry:$0,submissions:true) }
            .configurationDisplayName("在投状态持续时间 · Submission Duration")
            .description("查看论文当前状态持续天数与超期提醒。 · Track each paper's current status duration and overdue alerts.")
            .supportedFamilies([.systemMedium,.systemLarge])
    }
}
struct AchievementStatisticsWidget: Widget {
    let kind = "ResearchAchievementStatistics"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind:kind,provider:StatisticsProvider()) { StatisticsView(entry:$0,submissions:false) }
            .configurationDisplayName("成果与署名分布 · Achievements & Authorship")
            .description("成果类别与作者署名的组合统计。 · Combined statistics by work category and authorship.")
            .supportedFamilies([.systemLarge])
    }
}
#if !WIDGET_LAYOUT_TEST
@main struct ResearchWidgets: WidgetBundle {
    var body: some Widget { SubmissionDurationWidget(); AchievementStatisticsWidget() }
}

#endif
