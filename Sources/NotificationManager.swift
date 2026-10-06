import Foundation
import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()

    private init() {}

    func configure(
        store: PaperStore,
        settings: AppSettings,
        requestAuthorization: Bool
    ) async -> String {
        guard settings.notificationsEnabled else {
            center.removeAllPendingNotificationRequests()
            return AppLocalization.text("系统提醒已关闭。")
        }
        do {
            if requestAuthorization {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                guard granted else { return AppLocalization.text("未获得通知权限，请在系统设置中允许“搞研究”发送通知。") }
            } else {
                let authorization = await center.notificationSettings().authorizationStatus
                guard authorization == .authorized || authorization == .provisional else {
                    return AppLocalization.text("尚未开启通知权限。")
                }
            }

            center.removeAllPendingNotificationRequests()
            var requests: [UNNotificationRequest] = []
            requests.append(contentsOf: submissionRequests(
                papers: store.visiblePapers,
                thresholdDays: settings.submissionReminderDays
            ))
            requests.append(contentsOf: projectRequests(
                projects: store.projects,
                leadDays: settings.projectReminderLeadDays
            ))
            for request in requests.prefix(60) {
                try await center.add(request)
            }
            return AppLocalization.format("已安排 %d 条本机提醒。", min(60, requests.count))
        } catch {
            return AppLocalization.format("提醒设置失败：%@", error.localizedDescription)
        }
    }

    private func submissionRequests(papers: [PaperRecord], thresholdDays: Int) -> [UNNotificationRequest] {
        let calendar = Calendar.current
        let now = Date()
        return papers.compactMap { paper in
            guard !isTerminalStatus(paper.status),
                  let thresholdDate = calendar.date(byAdding: .day, value: thresholdDays, to: paper.statusSince)
            else { return nil }
            let notificationDate = nextUsableNotificationDate(preferred: thresholdDate, now: now)
            let content = UNMutableNotificationContent()
            content.title = AppLocalization.text("投稿状态提醒")
            content.body = AppLocalization.format(
                "“%@”保持“%@”状态已达到 %d 天，请考虑检查或更新。",
                paper.title,
                paper.status,
                thresholdDays
            )
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: notificationDate),
                repeats: false
            )
            return UNNotificationRequest(identifier: "submission-\(stableIdentifier(paper.id))", content: content, trigger: trigger)
        }
    }

    private func projectRequests(projects: [ResearchProject], leadDays: Int) -> [UNNotificationRequest] {
        let calendar = Calendar.current
        let now = Date()
        return projects.flatMap { project in
            project.steps.compactMap { step in
                guard !step.isCompleted,
                      let preferred = calendar.date(byAdding: .day, value: -leadDays, to: step.normalizedEndDate)
                else { return nil }
                let notificationDate = nextUsableNotificationDate(preferred: preferred, now: now)
                let content = UNMutableNotificationContent()
                content.title = AppLocalization.text("项目节点提醒")
                let days = calendar.dateComponents(
                    [.day],
                    from: calendar.startOfDay(for: now),
                    to: calendar.startOfDay(for: step.normalizedEndDate)
                ).day ?? 0
                content.body = days < 0
                    ? AppLocalization.format("“%@”的步骤“%@”已逾期 %d 天。", project.title, step.title, abs(days))
                    : AppLocalization.format("“%@”的步骤“%@”将在 %d 天后截止。", project.title, step.title, days)
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: notificationDate),
                    repeats: false
                )
                return UNNotificationRequest(
                    identifier: "project-\(stableIdentifier(project.id))-\(stableIdentifier(step.id))",
                    content: content,
                    trigger: trigger
                )
            }
        }
    }

    private func nextUsableNotificationDate(preferred: Date, now: Date) -> Date {
        let calendar = Calendar.current
        let preferredMorning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: preferred) ?? preferred
        if preferredMorning > now { return preferredMorning }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private func isTerminalStatus(_ status: String) -> Bool {
        SubmissionStatusClassifier.isTerminal(status)
    }

    private func stableIdentifier(_ value: String) -> String {
        String(value.unicodeScalars.map { String(format: "%02X", $0.value) }.joined().prefix(120))
    }
}
