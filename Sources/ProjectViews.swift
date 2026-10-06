import Charts
import SwiftUI
import UniformTypeIdentifiers

struct ProjectDashboard: View {
    @EnvironmentObject private var store: PaperStore
    let projects: [ResearchProject]
    let isSearching: Bool
    let openAction: (ResearchProject) -> Void
    let createAction: () -> Void
    @State private var editingProject: ResearchProject?
    @State private var projectPendingDeletion: ResearchProject?
    @State private var draggedProjectID: String?
    // V4.6 batch-T：项目拖动排序已接入后端 ResearchProject.sortOrder
    // （store.projects(matching:) 按 sortOrder 排序，moveProject 归一化并落盘）。

    var body: some View {
        Group {
        if projects.isEmpty {
            ListEmptyStateView(
                icon: "calendar.badge.plus",
                title: AppLocalization.text(isSearching ? "没有找到匹配的项目" : "还没有项目"),
                subtitle: AppLocalization.text(isSearching
                     ? "试试使用其他项目名称、内容或步骤关键词。"
                     : "创建项目并自定义具体步骤、时间节点和完成状态，甘特图会自动生成。"),
                buttonTitle: isSearching ? nil : AppLocalization.text("新建项目"),
                buttonAction: isSearching ? nil : createAction
            )
        } else {
            ScrollView {
                VStack(spacing: 18) {
                    ProjectGanttChart(projects: projects)

                    LazyVStack(spacing: 12) {
                        ForEach(projects) { project in
                            ProjectCard(project: project) { openAction(project) }
                                .onDrag {
                                    draggedProjectID = project.id
                                    return NSItemProvider(object: project.id as NSString)
                                }
                                .onDrop(
                                    of: [UTType.plainText],
                                    delegate: ReorderDropDelegate.project(
                                        targetID: project.id,
                                        draggedID: $draggedProjectID,
                                        store: store,
                                        isEnabled: !isSearching
                                    )
                                )
                                .help(AppLocalization.text("上下拖动调整顺序"))
                                .contextMenu {
                                    Button {
                                        openAction(project)
                                    } label: {
                                        Label(AppLocalization.text("查看详情"), systemImage: "doc.text.magnifyingglass")
                                    }
                                    Button {
                                        editingProject = project
                                    } label: {
                                        Label(AppLocalization.text("编辑"), systemImage: "square.and.pencil")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        projectPendingDeletion = project
                                    } label: {
                                        Label(AppLocalization.text("删除"), systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
                .frame(maxWidth: 1100)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
        }
        .sheet(item: $editingProject) { project in
            ProjectEditor(project: project)
                .environmentObject(store)
        }
        .alert(
            AppLocalization.text("删除该项目？"),
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { if !$0 { projectPendingDeletion = nil } }
            )
        ) {
            Button(AppLocalization.text("取消"), role: .cancel) {}
            Button(AppLocalization.text("删除"), role: .destructive) {
                if let project = projectPendingDeletion { store.deleteProject(project) }
                projectPendingDeletion = nil
            }
        } message: {
            Text(AppLocalization.text("项目内容、步骤和时间节点会移入回收站，可在30天内恢复。"))
        }
    }
}

private enum GanttState: String {
    case completed
    case overdue
    case active
    case upcoming

    var title: String {
        switch self {
        case .completed: AppLocalization.text("已完成")
        case .overdue: AppLocalization.text("已逾期")
        case .active: AppLocalization.text("进行中")
        case .upcoming: AppLocalization.text("未开始")
        }
    }

    var color: Color {
        switch self {
        case .completed: AppTheme.teal
        case .overdue: .red
        case .active: AppTheme.blue
        case .upcoming: .secondary
        }
    }
}

private struct GanttItem: Identifiable {
    let id: String
    let rowLabel: String
    let startDate: Date
    let chartEndDate: Date
    let state: GanttState
}

private struct GanttYearSlice: Identifiable {
    let item: GanttItem
    let year: Int
    let startDate: Date
    let endDate: Date

    var id: String { "\(item.id)-\(year)" }
}

struct ProjectGanttChart: View {
    let projects: [ResearchProject]

    private var items: [GanttItem] {
        projects.flatMap { project in
            project.steps.map { step in
                let state: GanttState
                let today = Calendar.current.startOfDay(for: Date())
                let start = Calendar.current.startOfDay(for: step.startDate)
                let end = Calendar.current.startOfDay(for: step.normalizedEndDate)
                if step.isCompleted {
                    state = .completed
                } else if end < today {
                    state = .overdue
                } else if start > today {
                    state = .upcoming
                } else {
                    state = .active
                }
                let chartEnd = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end
                let stepTitle = step.title.count > 18 ? "\(step.title.prefix(18))…" : step.title
                let projectTitle = project.title.count > 12 ? "\(project.title.prefix(12))…" : project.title
                return GanttItem(
                    id: "\(project.id)-\(step.id)",
                    rowLabel: "\(projectTitle) · \(stepTitle)",
                    startDate: start,
                    chartEndDate: chartEnd,
                    state: state
                )
            }
        }
        .sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.rowLabel < $1.rowLabel
        }
    }

    private var projectsWithoutSteps: Int { projects.filter { $0.steps.isEmpty }.count }

    private var years: [Int] {
        guard let first = items.map(\.startDate).min(),
              let last = items.map(\.chartEndDate).max() else { return [] }
        let calendar = Calendar.current
        let firstYear = calendar.component(.year, from: first)
        let lastYear = calendar.component(.year, from: last.addingTimeInterval(-1))
        return Array(firstYear...max(firstYear, lastYear))
    }

    private func bounds(for year: Int) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
        let end = calendar.date(byAdding: .year, value: 1, to: start)!
        return start...end
    }

    private func axisDates(for year: Int) -> [Date] {
        let calendar = Calendar.current
        return [1, 4, 7, 10, 12].compactMap {
            calendar.date(from: DateComponents(year: year, month: $0, day: 1))
        }
    }

    private func slices(for year: Int) -> [GanttYearSlice] {
        let domain = bounds(for: year)
        return items.compactMap { item in
            guard item.startDate < domain.upperBound, item.chartEndDate > domain.lowerBound else { return nil }
            return GanttYearSlice(
                item: item,
                year: year,
                startDate: max(item.startDate, domain.lowerBound),
                endDate: min(item.chartEndDate, domain.upperBound)
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.text("项目甘特图"))
                    .font(.headline)
                Text(AppLocalization.text("按项目步骤展示自定义开始、结束时间和完成状态"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty {
                Text(AppLocalization.text("为项目添加步骤和时间节点后，这里会自动生成甘特图。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                VStack(spacing: 18) {
                    HStack(spacing: 14) {
                        ForEach([
                            (GanttState.completed.title, AppTheme.teal),
                            (GanttState.overdue.title, Color.red),
                            (GanttState.active.title, AppTheme.blue),
                            (GanttState.upcoming.title, Color.secondary),
                        ], id: \.0) { label, color in
                            HStack(spacing: 5) {
                                Circle().fill(color).frame(width: 7, height: 7)
                                Text(label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }

                    ForEach(years, id: \.self) { year in
                        let yearSlices = slices(for: year)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(year))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Chart {
                                ForEach(yearSlices) { slice in
                                    BarMark(
                                        xStart: .value(AppLocalization.text("开始"), slice.startDate),
                                        xEnd: .value(AppLocalization.text("结束"), slice.endDate),
                                        y: .value(AppLocalization.text("项目步骤"), slice.item.rowLabel),
                                        height: .fixed(14)
                                    )
                                    .foregroundStyle(slice.item.state.color)
                                    .cornerRadius(4)
                                }

                                let today = Calendar.current.startOfDay(for: Date())
                                if Calendar.current.component(.year, from: today) == year {
                                    RuleMark(x: .value(AppLocalization.text("今天"), today))
                                        .foregroundStyle(Color.orange)
                                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                                        .annotation(position: .top, alignment: .leading) {
                                            Text(AppLocalization.text("今天"))
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(Color.orange)
                                        }
                                }
                            }
                            .chartXScale(domain: bounds(for: year))
                            .chartLegend(.hidden)
                            .chartXAxis {
                                AxisMarks(values: axisDates(for: year)) {
                                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                                    AxisValueLabel(
                                        format: .dateTime.month(.abbreviated)
                                            .locale(AppLocalization.language.locale)
                                    )
                                }
                            }
                            .chartPlotStyle { plot in plot.padding(.horizontal, 8) }
                            .frame(height: max(84, CGFloat(yearSlices.count) * 34 + 42))
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            if projectsWithoutSteps > 0 {
                Text(AppLocalization.format(
                    "另有 %d 个项目尚未添加步骤，暂未计入甘特图。",
                    projectsWithoutSteps
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
}

private struct ProjectCard: View {
    let project: ResearchProject
    let action: () -> Void

    private var overdueCount: Int {
        let today = Calendar.current.startOfDay(for: Date())
        return project.steps.filter {
            !$0.isCompleted && Calendar.current.startOfDay(for: $0.normalizedEndDate) < today
        }.count
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: project.isCompleted ? "checkmark.circle.fill" : "calendar.badge.clock")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(project.isCompleted ? AppTheme.teal : AppTheme.blue)
                    .frame(width: 38, height: 38)
                    .background((project.isCompleted ? AppTheme.teal : AppTheme.blue).opacity(0.09), in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(AppLocalization.text(project.isCompleted ? "已完成" : "进行中"))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(project.isCompleted ? AppTheme.teal : AppTheme.blue)
                        if let start = project.timelineStart, let end = project.timelineEnd {
                            Text("\(ProjectFormatters.shortDate.string(from: start)) – \(ProjectFormatters.shortDate.string(from: end))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(project.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !project.content.isEmpty {
                        Text(project.content)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 7) {
                    Text(AppLocalization.format("%d / %d 步骤", project.completedStepCount, project.steps.count))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ProgressView(value: project.progress)
                        .frame(width: 120)
                    if overdueCount > 0 {
                        Label(AppLocalization.format("%d 项逾期", overdueCount), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
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

struct ProjectEditor: View {
    @EnvironmentObject private var store: PaperStore
    @Environment(\.dismiss) private var dismiss

    private let existingID: String?
    @State private var title: String
    @State private var content: String
    @State private var steps: [ProjectStep]

    init(project: ResearchProject?) {
        existingID = project?.id
        _title = State(initialValue: project?.title ?? "")
        _content = State(initialValue: project?.content ?? "")
        _steps = State(initialValue: project?.steps ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            ProjectEditorHeader(
                title: existingID == nil ? "新建项目" : "编辑项目",
                subtitle: "自定义项目内容、具体步骤和每个时间节点。"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ProjectEditorGroup(title: "项目内容") {
                        TextField(AppLocalization.text("项目名称（必填）"), text: $title)
                        ProjectTextEditor(text: $content, prompt: "填写项目目标、研究内容、交付物或其他说明…", height: 118)
                    }

                    ProjectEditorGroup(title: "具体步骤与时间节点") {
                        HStack {
                            Text(AppLocalization.text("步骤可以自由添加、删除并设置起止日期。"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(action: addStep) {
                                Label(AppLocalization.text("添加步骤"), systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if steps.isEmpty {
                            Text(AppLocalization.text("尚未添加步骤。项目仍可保存，之后可以继续补充。"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 70, alignment: .center)
                        } else {
                            ForEach($steps) { $step in
                                ProjectStepEditor(step: $step) {
                                    steps.removeAll { $0.id == step.id }
                                }
                            }
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
                Button(AppLocalization.text("保存")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 760, height: 800)
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && steps.allSatisfy {
                !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.endDate >= $0.startDate
            }
    }

    private func addStep() {
        let calendar = Calendar.current
        let start = steps.last?.endDate ?? Date()
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        steps.append(ProjectStep(
            id: UUID().uuidString,
            title: "",
            details: "",
            startDate: start,
            endDate: end,
            isCompleted: false
        ))
    }

    private func save() {
        store.saveProject(existingID: existingID, title: title, content: content, steps: steps)
        dismiss()
    }
}

private struct ProjectStepEditor: View {
    @Binding var step: ProjectStep
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                TextField(AppLocalization.text("步骤名称（必填）"), text: $step.title)
                Toggle(AppLocalization.text("已完成"), isOn: $step.isCompleted)
                    .toggleStyle(.checkbox)
                Button(role: .destructive, action: deleteAction) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(AppLocalization.text("删除步骤"))
            }

            ProjectTextEditor(text: $step.details, prompt: "步骤说明、阶段目标或交付物…", height: 72)

            HStack(spacing: 18) {
                DatePicker(AppLocalization.text("开始日期"), selection: $step.startDate, displayedComponents: [.date])
                    .datePickerStyle(.field)
                DatePicker(AppLocalization.text("结束日期"), selection: $step.endDate, in: step.startDate..., displayedComponents: [.date])
                    .datePickerStyle(.field)
                Spacer()
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
        .onChange(of: step.startDate) { newStart in
            if step.endDate < newStart { step.endDate = newStart }
        }
    }
}

struct ProjectDetailView: View {
    @EnvironmentObject private var store: PaperStore
    @Environment(\.dismiss) private var dismiss
    let projectID: String

    @State private var editProject = false
    @State private var confirmDelete = false

    private var project: ResearchProject? { store.projects.first { $0.id == projectID } }

    var body: some View {
        Group {
            if let project {
                VStack(spacing: 0) {
                    HStack {
                        Text(AppLocalization.text("项目详情"))
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
                                Image(systemName: project.isCompleted ? "checkmark.circle.fill" : "calendar.badge.clock")
                                    .font(.title2.weight(.medium))
                                    .foregroundStyle(project.isCompleted ? AppTheme.teal : AppTheme.blue)
                                    .frame(width: 48, height: 48)
                                    .background((project.isCompleted ? AppTheme.teal : AppTheme.blue).opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(AppLocalization.text(project.isCompleted ? "项目已完成" : "项目进行中"))
                                        .font(.caption.bold())
                                        .foregroundStyle(project.isCompleted ? AppTheme.teal : AppTheme.blue)
                                    Text(project.title)
                                        .font(.system(size: 25, weight: .bold))
                                    if !project.content.isEmpty {
                                        Text(project.content)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text(AppLocalization.text("完成进度"))
                                        .font(.headline)
                                    Spacer()
                                    Text("\(project.completedStepCount) / \(project.steps.count)")
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                ProgressView(value: project.progress)
                                if let start = project.timelineStart, let end = project.timelineEnd {
                                    Text(AppLocalization.format("项目周期：%@ – %@", Formatters.longDate.string(from: start), Formatters.longDate.string(from: end)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(16)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))

                            VStack(alignment: .leading, spacing: 12) {
                                Text(AppLocalization.text("具体步骤与时间节点"))
                                    .font(.headline)
                                if project.steps.isEmpty {
                                    Text(AppLocalization.text("尚未添加步骤。"))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(project.steps) { step in
                                        HStack(alignment: .top, spacing: 12) {
                                            Toggle("", isOn: Binding(
                                                get: { step.isCompleted },
                                                set: { store.setProjectStepCompleted(projectID: project.id, stepID: step.id, isCompleted: $0) }
                                            ))
                                            .toggleStyle(.checkbox)
                                            .labelsHidden()
                                            .padding(.top, 2)

                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(step.title)
                                                    .font(.callout.weight(.semibold))
                                                    .strikethrough(step.isCompleted)
                                                Text("\(Formatters.longDate.string(from: step.startDate)) – \(Formatters.longDate.string(from: step.normalizedEndDate))")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                if !step.details.isEmpty {
                                                    Text(step.details)
                                                        .font(.callout)
                                                        .foregroundStyle(.secondary)
                                                        .textSelection(.enabled)
                                                }
                                            }
                                            Spacer()
                                        }
                                        .padding(12)
                                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                                    }
                                }
                            }

                            Divider()
                            HStack {
                                Button {
                                    editProject = true
                                } label: {
                                    Label(AppLocalization.text("编辑项目"), systemImage: "square.and.pencil")
                                }
                                .buttonStyle(.borderedProminent)
                                Spacer()
                                Button(AppLocalization.text("删除项目"), role: .destructive) { confirmDelete = true }
                            }
                        }
                        .padding(28)
                    }
                }
            } else {
                Text(AppLocalization.text("该项目已被删除。"))
                    .padding(40)
            }
        }
        .frame(minWidth: 720, minHeight: 680)
        .sheet(isPresented: $editProject) {
            ProjectEditor(project: project)
                .environmentObject(store)
        }
        .alert(AppLocalization.text("删除该项目？"), isPresented: $confirmDelete) {
            Button(AppLocalization.text("取消"), role: .cancel) {}
            Button(AppLocalization.text("删除"), role: .destructive) {
                if let project { store.deleteProject(project) }
                dismiss()
            }
        } message: {
            Text(AppLocalization.text("项目内容、步骤和时间节点会移入回收站，可在30天内恢复。"))
        }
    }
}

private struct ProjectEditorGroup<Content: View>: View {
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

private struct ProjectTextEditor: View {
    @Binding var text: String
    let prompt: String
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(AppLocalization.text(prompt))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .padding(3)
        }
        .frame(height: height)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.14)))
    }
}

private struct ProjectEditorHeader: View {
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

private enum ProjectFormatters {
    static var shortDate: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLocalization.language.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }
}
