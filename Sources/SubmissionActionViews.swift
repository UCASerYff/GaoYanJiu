import Combine
import SwiftUI

private func submissionActionDateLabel(_ day: SubmissionActionDay, calendar: Calendar) -> String {
    guard let date = day.date(in: calendar) else { return day.rawValue }
    let formatter = DateFormatter()
    formatter.locale = AppLocalization.language.locale
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateStyle = .medium
    return formatter.string(from: date)
}

struct SubmissionActionBoard: View {
    @EnvironmentObject private var store: PaperStore
    @State private var now = Date()
    @State private var laterExpanded = false
    @State private var failure: String?
    let openPaper: (PaperRecord) -> Void

    var body: some View {
        let calendar = SubmissionActionDay.localCalendar()
        let sections = SubmissionActionSection.grouped(store.papers, now: now, calendar: calendar)
        let immediate = sections.filter { $0.kind != .later }
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalization.text("下一步行动"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 8) {
                ForEach(immediate) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        heading(section)
                            .padding(8)
                        groupRows(section, calendar: calendar)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppTheme.border))
                }
            }
            if let later = sections.first(where: { $0.kind == .later && !$0.rows.isEmpty }) {
                DisclosureGroup(isExpanded: $laterExpanded) {
                    groupRows(later, calendar: calendar)
                } label: {
                    heading(later)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(AppTheme.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppTheme.border))
            }
            if sections.allSatisfy({ $0.rows.isEmpty }) {
                Text(AppLocalization.text("暂无未完成的行动。可在稿件详情中设置。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .workspaceCard(cornerRadius: 11, padding: 12)
        .onAppear { now = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in now = Date() }
        .alert(AppLocalization.text("无法更新行动"), isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button(AppLocalization.text("好"), role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func heading(_ section: SubmissionActionSection) -> some View {
        HStack(spacing: 6) {
            Text(section.kind.title)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(section.rows.count)")
                .monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(section.kind == .overdue && !section.rows.isEmpty ? AppTheme.clay : Color.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func groupRows(_ section: SubmissionActionSection, calendar: Calendar) -> some View {
        if section.rows.count > 3 {
            ScrollView { rows(section, calendar: calendar) }
                .frame(height: 183)
        } else {
            rows(section, calendar: calendar)
        }
    }

    private func rows(_ section: SubmissionActionSection, calendar: Calendar) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(section.rows) { row in
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.plan.text)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .help(row.plan.text)
                    Button(row.paper.title) { openPaper(row.paper) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .lineLimit(2)
                        .help(row.paper.title)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(submissionActionDateLabel(row.plan.dueDate, calendar: calendar))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button(AppLocalization.text("完成行动")) {
                            do {
                                try store.changeSubmissionAction(paperID: row.id, revision: row.plan.revision, change: .complete)
                            } catch { failure = error.localizedDescription }
                        }
                        .controlSize(.small)
                        .disabled(store.libraryLoadFailed)
                        .accessibilityLabel(AppLocalization.format("完成行动：%@", row.plan.text))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct SubmissionActionDetail: View {
    @EnvironmentObject private var store: PaperStore
    @State private var draft: SubmissionActionDraft?
    @State private var removalRevision: String?
    @State private var confirmingRemoval = false
    @State private var failure: String?
    let paper: PaperRecord

    var body: some View {
        let plan = paper.nextAction?.plan
        if paper.canScheduleNextAction || plan != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(AppLocalization.text("下一步行动"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if let plan {
                        Spacer()
                        Text(AppLocalization.text(plan.completedAt == nil ? "未完成" : "已完成"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(plan.completedAt == nil ? AppTheme.clay : AppTheme.teal)
                    }
                }
                if let plan {
                    Text(plan.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    let deadline = submissionActionDateLabel(plan.dueDate, calendar: SubmissionActionDay.localCalendar())
                    Text(AppLocalization.format("截止：%@", deadline))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let completedAt = plan.completedAt {
                        Text(AppLocalization.format("完成于：%@", Formatters.dateTime.string(from: completedAt)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if paper.canScheduleNextAction {
                        let label = plan == nil ? "设置行动" : plan?.completedAt == nil ? "编辑行动" : "添加新行动"
                        Button(AppLocalization.text(label)) { draft = SubmissionActionDraft(paper: paper) }
                    }
                    if let plan {
                        if plan.completedAt == nil {
                            Button(AppLocalization.text("标记完成")) { apply(.complete, revision: plan.revision) }
                                .buttonStyle(.borderedProminent)
                                .tint(AppTheme.accent)
                        } else if paper.canScheduleNextAction {
                            Button(AppLocalization.text("重新打开行动")) { apply(.reopen, revision: plan.revision) }
                        }
                        Button(AppLocalization.text("移除行动"), role: .destructive) {
                            removalRevision = plan.revision
                            confirmingRemoval = true
                        }
                    }
                }
                .disabled(store.libraryLoadFailed)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .workspaceCard(cornerRadius: 12, padding: 14)
            .sheet(item: $draft) { draft in
                SubmissionActionEditor(draft: draft) { text, dueDate in
                    try store.changeSubmissionAction(paperID: draft.paperID, revision: draft.revision, change: .save(text, dueDate))
                }
            }
            .confirmationDialog(AppLocalization.text("移除下一步行动？"), isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button(AppLocalization.text("移除行动"), role: .destructive) {
                    if let revision = removalRevision { apply(.remove, revision: revision) }
                }
            }
            .alert(AppLocalization.text("无法更新行动"), isPresented: Binding(
                get: { failure != nil }, set: { if !$0 { failure = nil } }
            )) {
                Button(AppLocalization.text("好"), role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private func apply(_ change: SubmissionActionChange, revision: String) {
        do { try store.changeSubmissionAction(paperID: paper.id, revision: revision, change: change) }
        catch { failure = error.localizedDescription }
    }
}

private struct SubmissionActionDraft: Identifiable {
    let id = UUID()
    let paperID: String
    let paperTitle: String
    let revision: String?
    let text: String
    let dueDate: Date
    let isEditing: Bool

    init(paper: PaperRecord) {
        paperID = paper.id
        paperTitle = paper.title
        let plan = paper.nextAction?.plan
        revision = plan?.revision
        let pending = plan?.completedAt == nil ? plan : nil
        text = pending?.text ?? ""
        dueDate = pending?.dueDate.date(in: SubmissionActionDay.localCalendar()) ?? Date()
        isEditing = pending != nil
    }
}

private struct SubmissionActionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusText: Bool
    @State private var text: String
    @State private var dueDate: Date
    @State private var failure: String?
    let draft: SubmissionActionDraft
    let save: (String, SubmissionActionDay) throws -> Void

    init(draft: SubmissionActionDraft, save: @escaping (String, SubmissionActionDay) throws -> Void) {
        self.draft = draft
        self.save = save
        _text = State(initialValue: draft.text)
        _dueDate = State(initialValue: draft.dueDate)
    }

    var body: some View {
        let calendar = SubmissionActionDay.localCalendar()
        VStack(alignment: .leading, spacing: 14) {
            Text(AppLocalization.text(draft.isEditing ? "编辑下一步行动" : "设置下一步行动"))
                .font(.headline)
            Text(draft.paperTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            TextField(AppLocalization.text("具体行动"), text: $text,
                      prompt: Text(AppLocalization.text("例如：整理审稿意见并提交修订稿")))
                .textFieldStyle(.roundedBorder)
                .focused($focusText)
            DatePicker(AppLocalization.text("截止日期"), selection: $dueDate, displayedComponents: .date)
                .environment(\.calendar, calendar)
            if let error = failure ?? (text.unicodeScalars.count > SubmissionAction.textLimit
                                       ? SubmissionActionError.invalidText.localizedDescription : nil) {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(AppTheme.clay)
            }
            HStack {
                Spacer()
                Button(AppLocalization.text("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppLocalization.text("保存")) {
                    do {
                        guard let day = SubmissionActionDay(date: dueDate, calendar: calendar) else {
                            throw SubmissionActionError.invalidDate
                        }
                        try save(text, day)
                        dismiss()
                    } catch { failure = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .disabled(SubmissionAction.cleanedText(text) == nil)
            }
        }
        .padding(20)
        .frame(width: 435)
        .onAppear { focusText = true }
    }
}
