import Foundation
import Security

struct PortalCredential: Codable, Equatable, Identifiable {
    var username: String
    var password: String
    var loginURL: String?

    var id: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    init(username: String, password: String, loginURL: String? = nil) {
        self.username = username
        self.password = password
        self.loginURL = loginURL
    }
}

enum PortalCredentialStore {
    private static let service = "com.gaoseries.GaoQiNianSan.portal-credentials"

    static func key(for urlString: String, publisher: PublisherDefinition) -> String {
        guard let components = URLComponents(string: urlString) else {
            return "\(publisher.kind)|\(urlString.lowercased())"
        }
        let host = (components.host ?? publisher.id).lowercased()
            .replacingOccurrences(of: "www.", with: "")
        let path = components.path.split(separator: "/").first?.lowercased() ?? ""
        let pathScoped = [
            "editorial-manager", "scholarone", "editorial-express", "ejournalpress",
            "benchpress", "manuscript-manager", "kriyadocs", "ojs", "janeway", "generic",
        ].contains(publisher.kind)
        return pathScoped ? "\(publisher.kind)|\(host)/\(path)" : "\(publisher.kind)|\(host)"
    }

    /// V2.1 stored one PortalCredential at this key. Decoding that legacy
    /// shape preserves it automatically when V2.2 first reads the portal.
    static func loadAll(key: String) -> [PortalCredential] {
        guard let data = readData(key: key) else { return [] }
        if let credentials = try? JSONDecoder().decode([PortalCredential].self, from: data) {
            return deduplicated(credentials)
        }
        if let legacy = try? JSONDecoder().decode(PortalCredential.self, from: data) {
            return [legacy]
        }
        return []
    }

    static func load(key: String) -> PortalCredential? {
        loadAll(key: key).first
    }

    static func save(_ credential: PortalCredential, key: String) throws {
        let username = credential.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !credential.password.isEmpty else {
            throw StoreError.incompleteCredential
        }
        let clean = PortalCredential(
            username: username,
            password: credential.password,
            loginURL: normalizedLoginURL(credential.loginURL)
        )
        let credentials = merging(clean, into: loadAll(key: key))
        try write(try JSONEncoder().encode(credentials), key: key)
    }

    static func delete(key: String, credentialID: String) {
        let remaining = loadAll(key: key).filter { $0.id != credentialID }
        guard !remaining.isEmpty else {
            delete(key: key)
            return
        }
        try? write(try JSONEncoder().encode(remaining), key: key)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func merging(_ credential: PortalCredential, into existing: [PortalCredential]) -> [PortalCredential] {
        var result = deduplicated(existing)
        if let index = result.firstIndex(where: { $0.id == credential.id }) {
            result[index] = credential
        } else {
            result.append(credential)
        }
        return result.sorted {
            $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
        }
    }

    private static func deduplicated(_ credentials: [PortalCredential]) -> [PortalCredential] {
        var seen = Set<String>()
        return Array(credentials.reversed().filter { seen.insert($0.id).inserted }.reversed())
    }

    private static func normalizedLoginURL(_ value: String?) -> String? {
        guard let value,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        return url.absoluteString
    }

    private static func readData(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ data: Data, key: String) throws {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let updateStatus = SecItemUpdate(
            lookup as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var item = lookup
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw StoreError.keychain(status) }
        } else if updateStatus != errSecSuccess {
            throw StoreError.keychain(updateStatus)
        }
    }

    private enum StoreError: LocalizedError {
        case incompleteCredential
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .incompleteCredential:
                return AppLocalization.text("请填写账号和密码。")
            case .keychain(let status):
                return (SecCopyErrorMessageString(status, nil) as String?)
                    ?? AppLocalization.text("无法访问 macOS 钥匙串。")
            }
        }
    }
}
