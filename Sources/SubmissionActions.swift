import Foundation

struct SubmissionActionDay: RawRepresentable, Comparable, Hashable {
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.utf8.count == 10 else { return nil }
        let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].utf8.count == 4, parts[1].utf8.count == 2, parts[2].utf8.count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              year > 0, (1...12).contains(month), day > 0 else { return nil }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= days[month - 1] else { return nil }
        self.rawValue = rawValue
    }

    init?(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard components.era == 1, let year = components.year, let month = components.month,
              let day = components.day else { return nil }
        self.init(rawValue: String(format: "%04d-%02d-%02d", year, month, day))
    }

    func date(in calendar: Calendar) -> Date? {
        let parts = rawValue.split(separator: "-").compactMap { Int($0) }
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
              Self(date: date, calendar: calendar) == self else { return nil }
        return date
    }

    static func < (left: Self, right: Self) -> Bool { left.rawValue < right.rawValue }

    static func localCalendar(timeZone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

struct SubmissionAction: Codable, Hashable {
    struct Plan: Hashable {
        let revision: String
        let text: String
        let dueDate: SubmissionActionDay
        let updatedAt: Date
        let completedAt: Date?
    }

    static let textLimit = 240
    private let raw: GaoJSONValue
    let plan: Plan?

    private init(raw: GaoJSONValue) {
        self.raw = raw
        plan = Self.readPlan(raw.objectValue)
    }

    init(from decoder: Decoder) throws { self.init(raw: try GaoJSONValue(from: decoder)) }
    func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }
    func hash(into hasher: inout Hasher) { hasher.combine(plan) }

    private static func readPlan(_ fields: [String: GaoJSONValue]?) -> Plan? {
        guard let fields,
              let revision = fields["revision"]?.stringValue, revision.utf8.count == 32,
              let text = fields["text"]?.stringValue, cleanedText(text) != nil,
              let stamp = fields["dueDate"]?.stringValue, let dueDate = SubmissionActionDay(rawValue: stamp),
              let updated = fields["updatedAt"]?.stringValue, let updatedAt = GaoActionISO8601.date(updated) else { return nil }
        let completedAt: Date?
        switch fields["completedAt"] {
        case nil, .null?: completedAt = nil
        case .string(let value)?:
            guard let parsed = GaoActionISO8601.date(value) else { return nil }
            completedAt = parsed
        default: return nil
        }
        return Plan(revision: revision, text: text, dueDate: dueDate, updatedAt: updatedAt, completedAt: completedAt)
    }

    static func cleanedText(_ text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleaned.isEmpty && cleaned.unicodeScalars.count <= textLimit ? cleaned : nil
    }

    static func updating(_ original: Self?, text: String, dueDate: SubmissionActionDay,
                         completedAt: Date?, now: Date) -> Self {
        // Keep forward-compatible keys when this platform edits an existing plan.
        var fields = original?.raw.objectValue ?? [:]
        fields["revision"] = .string(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        fields["text"] = .string(text)
        fields["dueDate"] = .string(dueDate.rawValue)
        fields["updatedAt"] = .string(GaoActionISO8601.string(now))
        fields["completedAt"] = completedAt.map { .string(GaoActionISO8601.string($0)) } ?? .null
        return Self(raw: .object(fields))
    }
}

enum SubmissionActionChange {
    case save(String, SubmissionActionDay)
    case complete, reopen, remove
}

enum SubmissionActionError: LocalizedError {
    case missingPaper, inactivePaper, stalePlan, missingPlan, invalidText, invalidDate

    var errorDescription: String? {
        switch self {
        case .missingPaper: AppLocalization.text("这篇论文已被删除。")
        case .inactivePaper: AppLocalization.text("只有仍在投且未归档的稿件可以安排新行动。")
        case .stalePlan: AppLocalization.text("行动已更新，请重新打开后继续。")
        case .missingPlan: AppLocalization.text("稿件没有可更新的行动。")
        case .invalidText: AppLocalization.text("请输入 1 至 240 个字的具体行动。")
        case .invalidDate: AppLocalization.text("请选择有效的截止日期。")
        }
    }
}

struct SubmissionActionSection: Identifiable {
    enum Kind: CaseIterable, Hashable {
        case overdue, today, upcoming, later

        var title: String {
            switch self {
            case .overdue: AppLocalization.text("已逾期")
            case .today: AppLocalization.text("今天到期")
            case .upcoming: AppLocalization.text("临近（7 天内）")
            case .later: AppLocalization.text("稍后（7 天以后）")
            }
        }
    }

    struct Row: Identifiable {
        let paper: PaperRecord
        let plan: SubmissionAction.Plan
        var id: String { paper.id }
    }

    let kind: Kind
    let rows: [Row]
    var id: Kind { kind }

    static func grouped(_ papers: [PaperRecord], now: Date, calendar: Calendar) -> [Self] {
        guard let today = SubmissionActionDay(date: now, calendar: calendar),
              let endDate = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)),
              let weekEnd = SubmissionActionDay(date: endDate, calendar: calendar) else { return [] }
        var sections: [Kind: [Row]] = [:]
        for paper in papers where paper.canScheduleNextAction {
            guard let plan = paper.nextAction?.plan, plan.completedAt == nil else { continue }
            let kind: Kind
            if plan.dueDate < today { kind = .overdue }
            else if plan.dueDate == today { kind = .today }
            else if plan.dueDate <= weekEnd { kind = .upcoming }
            else { kind = .later }
            sections[kind, default: []].append(Row(paper: paper, plan: plan))
        }
        return Kind.allCases.map { kind in
            Self(kind: kind, rows: (sections[kind] ?? []).sorted { left, right in
                if left.plan.dueDate != right.plan.dueDate { return left.plan.dueDate < right.plan.dueDate }
                let titleOrder = left.paper.title.localizedStandardCompare(right.paper.title)
                return titleOrder == .orderedSame ? left.id < right.id : titleOrder == .orderedAscending
            })
        }
    }
}
