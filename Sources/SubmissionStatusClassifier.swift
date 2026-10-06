import Foundation

/// 投稿状态终态判断的唯一权威来源。
///
/// 关键词列表是以下两处原列表的并集（均为子串包含匹配，大小写不敏感）：
/// - NotificationManager.isTerminalStatus（原实现）：
///   accept / publish / reject / withdraw / declin / 已接受 / 已发表 / 已拒 / 已撤
/// - WidgetExport（原实现）：
///   已接受 / 接收 / 录用 / 拒稿 / 撤稿 / accepted / accept / rejected / reject /
///   declined / withdrawn / withdraw / cancelled / canceled
///
/// 并集后按子串包含关系去重：accept 覆盖 accepted、reject 覆盖 rejected、
/// declin 覆盖 declined、withdraw 覆盖 withdrawn、cancel 覆盖 cancelled/canceled。
/// WidgetExport 独有的“接收 / 录用 / 拒稿 / 撤稿 / cancel”与
/// NotificationManager 独有的“publish / 已发表 / 已拒 / 已撤”均已并入。
enum SubmissionStatusClassifier {
    /// 终态关键词（全部小写；匹配时对状态文本先 lowercased 再做子串包含判断）。
    static let terminalKeywords: [String] = [
        // 英文
        "accept",   // 覆盖 accepted
        "publish",  // 覆盖 published / online 等发表类表述
        "reject",   // 覆盖 rejected
        "withdraw", // 覆盖 withdrawn
        "declin",   // 覆盖 declined / declining
        "cancel",   // 覆盖 cancelled / canceled
        // 中文
        "已接受",
        "接收",
        "录用",
        "已发表",
        "拒稿",
        "已拒",
        "撤稿",
        "已撤",
    ]

    /// 判断投稿状态是否为终态（不再需要提醒 / 不再计入进行中）。
    static func isTerminal(_ status: String) -> Bool {
        let value = status.lowercased()
        return terminalKeywords.contains { value.contains($0) }
    }
}
