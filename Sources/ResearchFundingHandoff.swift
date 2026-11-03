import Foundation

/// Original funding stays a read-only migration source. Opening Savings does
/// not import records, confirm payments, or award coins.
enum ResearchFundingHandoff {
    static let targetBundleID = "com.gaojixu.savings"
    static let minimumTargetVersion = [4, 4]
    static let readOnlyMessage = "资金管理已迁至搞积蓄。研究中的原记录与回收项保留为只读恢复依据；请在搞积蓄完成迁移后管理。"

    static func protectsTrash(kind: String, containsFunding: Bool) -> Bool {
        kind == "funding" || containsFunding
    }

    static func supportsTargetVersion(_ raw: String) -> Bool {
        let fields = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard !fields.isEmpty, fields.count <= 4,
              fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return false }
        let parts = fields.compactMap { Int($0) }
        guard parts.count == fields.count else { return false }
        let padded = parts + Array(repeating: 0, count: max(0, minimumTargetVersion.count - parts.count))
        for (lhs, rhs) in zip(padded, minimumTargetVersion) {
            if lhs != rhs { return lhs > rhs }
        }
        return true
    }

    static func destination(recordID: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "gaojixu"
        components.host = "research-funding"
        components.queryItems = [URLQueryItem(name: "source", value: "research")]
        if let recordID, !recordID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            components.queryItems?.append(URLQueryItem(name: "id", value: recordID))
        }
        return components.url!
    }

    static func legacyRecordID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "gaoyanjiu", url.host?.lowercased() == "funding" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "recordID" || $0.name == "sourceID" })?.value
    }
}
