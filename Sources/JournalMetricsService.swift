import Foundation
import Security

struct JournalSuggestion: Identifiable, Hashable {
    var title: String
    var issn: String
    var publisher: String

    var id: String { "\(title.lowercased())|\(issn.lowercased())" }
}

enum JournalSuggestionService {
    static func suggestions(for query: String) async throws -> [JournalSuggestion] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        var components = URLComponents(string: "https://api.crossref.org/journals")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "rows", value: "8"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("搞研究/3.0 macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let items = message["items"] as? [[String: Any]] else { return [] }

        var seen = Set<String>()
        return items.compactMap { item in
            let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            let issns = item["ISSN"] as? [String] ?? []
            let issn = issns.first ?? ""
            let publisher = (item["publisher"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let identity = "\(title.lowercased())|\(issn.lowercased())"
            guard seen.insert(identity).inserted else { return nil }
            return JournalSuggestion(title: title, issn: issn, publisher: publisher)
        }
    }
}

enum EasyScholarSecretKeyStore {
    private static let service = "com.gaoseries.GaoQiNianSan.easyscholar"
    private static let account = "open-api-secret-key"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete()
            return
        }
        let data = Data(trimmed.utf8)
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = lookup
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? AppLocalization.text("无法访问 macOS 钥匙串")
        }
    }
}

enum EasyScholarLookupError: LocalizedError {
    case missingKey
    case invalidQuery
    case invalidResponse
    case service(String)
    case noMetrics

    var errorDescription: String? {
        switch self {
        case .missingKey: AppLocalization.text("请先填写 EasyScholar Secret Key。")
        case .invalidQuery: AppLocalization.text("请填写期刊名称或 ISSN。")
        case .invalidResponse: AppLocalization.text("EasyScholar 返回了无法识别的结果。")
        case .service(let message): message
        case .noMetrics: AppLocalization.text("未查到该期刊的收录或评价信息，请检查刊名或 ISSN。")
        }
    }
}

enum EasyScholarJournalMetricsService {
    private struct Descriptor {
        let label: String
        let group: JournalMetricGroup
        let order: Int
    }

    static func lookup(query: String, secretKey: String) async throws -> JournalMetricsSnapshot {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else { throw EasyScholarLookupError.invalidQuery }
        guard !cleanKey.isEmpty else { throw EasyScholarLookupError.missingKey }

        var components = URLComponents(string: "https://www.easyscholar.cc/open/getPublicationRank")!
        components.queryItems = [
            URLQueryItem(name: "secretKey", value: cleanKey),
            URLQueryItem(name: "publicationName", value: cleanQuery),
        ]
        guard let url = components.url else { throw EasyScholarLookupError.invalidQuery }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("搞研究/3.0 macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw EasyScholarLookupError.service(AppLocalization.text("无法连接 EasyScholar，请稍后重试。"))
        }
        return try parse(data: data, query: cleanQuery)
    }

    static func parse(data: Data, query: String) throws -> JournalMetricsSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EasyScholarLookupError.invalidResponse
        }
        let code = (root["code"] as? NSNumber)?.intValue
            ?? Int(root["code"] as? String ?? "")
            ?? -1
        guard code == 200 else {
            let message = cleanString(root["msg"]) ?? AppLocalization.text("EasyScholar 查询失败。")
            throw EasyScholarLookupError.service(message)
        }
        guard let payload = root["data"] as? [String: Any],
              let official = payload["officialRank"] as? [String: Any] else {
            throw EasyScholarLookupError.invalidResponse
        }

        var ranks = official["all"] as? [String: Any] ?? [:]
        if let selected = official["select"] as? [String: Any] {
            for (key, value) in selected where ranks[key] == nil { ranks[key] = value }
        }

        var items = ranks.compactMap { key, rawValue -> JournalMetricItem? in
            guard let value = cleanString(rawValue) else { return nil }
            let descriptor = descriptors[key] ?? Descriptor(
                label: key.uppercased(),
                group: .other,
                order: 1_000
            )
            return JournalMetricItem(
                key: key,
                label: descriptor.label,
                value: value,
                group: descriptor.group,
                order: descriptor.order
            )
        }
        items.append(contentsOf: customMetricItems(from: payload))
        var seenKeys = Set<String>()
        var seenMetrics = Set<String>()
        items = items.filter {
            let metricIdentity = $0.displayText.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return seenKeys.insert($0.key.lowercased()).inserted
                && seenMetrics.insert(metricIdentity).inserted
        }
        guard !items.isEmpty else { throw EasyScholarLookupError.noMetrics }

        let matchedName = cleanString(payload["publicationName"])
            ?? cleanString(payload["paperName"])
            ?? cleanString(payload["name"])
            ?? query
        return JournalMetricsSnapshot(
            query: query,
            matchedJournalName: matchedName,
            source: "EasyScholar",
            casEdition: "2025",
            lookedUpAt: Date(),
            items: items
        )
    }

    private static func cleanString(_ value: Any?) -> String? {
        guard let value else { return nil }
        let result: String
        switch value {
        case let string as String:
            result = string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                guard number.boolValue else { return nil }
                result = "是"
            } else {
                result = number.stringValue
            }
        case let values as [Any]:
            result = values.compactMap(cleanString).joined(separator: "、")
        case let dictionary as [String: Any]:
            result = dictionary.sorted { $0.key < $1.key }
                .compactMap { key, value in cleanString(value).map { "\(key)：\($0)" } }
                .joined(separator: "；")
        default:
            return nil
        }
        let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let ignored = ["", "-", "null", "undefined", "none", "false", "否", "无"]
        return ignored.contains(clean.lowercased()) ? nil : clean
    }

    private static func customMetricItems(from payload: [String: Any]) -> [JournalMetricItem] {
        guard let custom = payload["customRank"] as? [String: Any],
              let ranks = custom["rank"] as? [String] else { return [] }

        let rawInfos: [[String: Any]]
        if let array = custom["rankInfo"] as? [[String: Any]] {
            rawInfos = array
        } else if let dictionary = custom["rankInfo"] as? [String: [String: Any]] {
            rawInfos = dictionary.map { key, value in
                var info = value
                if info["uuid"] == nil { info["uuid"] = key }
                return info
            }
        } else {
            rawInfos = []
        }
        var infos: [String: [String: Any]] = [:]
        for info in rawInfos {
            if let uuid = cleanString(info["uuid"]) { infos[uuid] = info }
        }
        let levelKeys = ["oneRankText", "twoRankText", "threeRankText", "fourRankText", "fiveRankText"]

        return ranks.enumerated().compactMap { index, rawRank in
            let components = rawRank.components(separatedBy: "&&&")
            guard components.count == 2,
                  let info = infos[components[0]],
                  let level = Int(components[1]),
                  (1...5).contains(level) else { return nil }
            let label = cleanString(info["abbName"])
                ?? cleanString(info["name"])
                ?? "自定义评价"
            let value = cleanString(info[levelKeys[level - 1]]) ?? "\(level) 级"
            let chineseKeywords = ["核心", "AMI", "CSSCI", "CSCD", "RCCSE", "中文", "中国科技"]
            let group: JournalMetricGroup = chineseKeywords.contains(where: {
                label.localizedCaseInsensitiveContains($0)
            }) ? .chineseCore : .other
            return JournalMetricItem(
                key: "custom:\(components[0])",
                label: label,
                value: value,
                group: group,
                order: 2_000 + index
            )
        }
    }

    private static let descriptors: [String: Descriptor] = [
        "sci": .init(label: "SCIE / JCR 分区", group: .internationalIndex, order: 10),
        "ssci": .init(label: "SSCI / JCR 分区", group: .internationalIndex, order: 20),
        "esci": .init(label: "ESCI", group: .internationalIndex, order: 30),
        "eii": .init(label: "EI", group: .internationalIndex, order: 40),
        "ei": .init(label: "EI", group: .internationalIndex, order: 40),
        "ahci": .init(label: "A&HCI", group: .internationalIndex, order: 50),
        "scopus": .init(label: "Scopus", group: .internationalIndex, order: 60),
        "sciUp": .init(label: "大类分区", group: .casPartition, order: 10),
        "sciUpSmall": .init(label: "小类分区", group: .casPartition, order: 20),
        "sciUpTop": .init(label: "Top 期刊", group: .casPartition, order: 30),
        "sciBase": .init(label: "基础版分区", group: .casPartition, order: 40),
        "sciwarn": .init(label: "预警期刊", group: .casPartition, order: 50),
        "sciif": .init(label: "影响因子 IF", group: .impact, order: 10),
        "sciif5": .init(label: "五年影响因子", group: .impact, order: 20),
        "jci": .init(label: "JCI", group: .impact, order: 30),
        "esi": .init(label: "ESI 学科", group: .impact, order: 40),
        "pku": .init(label: "北大中文核心", group: .chineseCore, order: 10),
        "cssci": .init(label: "CSSCI 南大核心", group: .chineseCore, order: 20),
        "cscd": .init(label: "CSCD", group: .chineseCore, order: 30),
        "zhongguokejihexin": .init(label: "中国科技核心", group: .chineseCore, order: 40),
        "cstpcd": .init(label: "中国科技核心", group: .chineseCore, order: 40),
        "ami": .init(label: "AMI 核心", group: .chineseCore, order: 50),
        "rccse": .init(label: "RCCSE 武大核心", group: .chineseCore, order: 60),
        "scd": .init(label: "SCD 源期刊", group: .chineseCore, order: 70),
        "ccf": .init(label: "CCF", group: .other, order: 10),
        "ajg": .init(label: "AJG", group: .other, order: 20),
        "fms": .init(label: "FMS", group: .other, order: 30),
        "ft50": .init(label: "FT50", group: .other, order: 40),
        "utd24": .init(label: "UTD24", group: .other, order: 50),
        "swufe": .init(label: "西南财经大学", group: .other, order: 100),
        "cufe": .init(label: "中央财经大学", group: .other, order: 110),
        "uibe": .init(label: "对外经济贸易大学", group: .other, order: 120),
        "sdufe": .init(label: "山东财经大学", group: .other, order: 130),
        "xdu": .init(label: "西安电子科技大学", group: .other, order: 140),
        "swjtu": .init(label: "西南交通大学", group: .other, order: 150),
        "ruc": .init(label: "中国人民大学", group: .other, order: 160),
        "xmu": .init(label: "厦门大学", group: .other, order: 170),
        "sjtu": .init(label: "上海交通大学", group: .other, order: 180),
        "fdu": .init(label: "复旦大学", group: .other, order: 190),
        "hhu": .init(label: "河海大学", group: .other, order: 200),
        "cqu": .init(label: "重庆大学", group: .other, order: 210),
        "nju": .init(label: "南京大学", group: .other, order: 220),
        "xju": .init(label: "新疆大学", group: .other, order: 230),
        "cug": .init(label: "中国地质大学", group: .other, order: 240),
        "cpu": .init(label: "中国药科大学", group: .other, order: 250),
        "scu": .init(label: "四川大学", group: .other, order: 260),
        "zju": .init(label: "浙江大学", group: .other, order: 270),
        "cju": .init(label: "长江大学", group: .other, order: 280),
    ]
}
