import CryptoKit
import Foundation

struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

struct EnvelopeWindow {
    let created: Date
    let expires: Date

    init(_ data: Data) throws {
        struct WireDates: Decodable {
            let createdAt: String
            let expiresAt: String
        }
        let wire = try JSONDecoder().decode(WireDates.self, from: data)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        func parse(_ value: String) throws -> Date {
            guard let date = fractional.date(from: value) ?? whole.date(from: value) else {
                throw FixtureFailure(description: "Unreadable production envelope time: " + value)
            }
            return date
        }
        created = try parse(wire.createdAt)
        expires = try parse(wire.expiresAt)
    }

    var resultTime: Date {
        // Exactly representable binary quarter-second, strictly after either native request spelling.
        Date(timeIntervalSince1970: floor(created.timeIntervalSince1970) + 2.25)
    }

    func reviewTime(_ result: EnvelopeWindow) throws -> Date {
        let time = max(created, result.created).addingTimeInterval(1)
        try require(time < min(expires, result.expires), "production envelope windows do not overlap")
        return time
    }
}

struct Fixture {
    static let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    static let provider = "com.gaoseries.GaoCaoZuo"
    static let files = "com.gaoseries.GaoWenJian"
    static let research = "com.academic-achievement.manager"
    static let items = "OCR fixture text from a synthetic source."

    let root: URL
    let mode: String

    init() throws {
        guard CommandLine.arguments.count == 3 else {
            throw FixtureFailure(description: "Usage: fixture absolute-isolated-root phase")
        }
        root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        mode = CommandLine.arguments[2]
        guard root.lastPathComponent == "fixture.noindex",
              root.deletingLastPathComponent().lastPathComponent.hasPrefix("gao-ocr-spool.") else {
            throw FixtureFailure(description: "Refusing a non-fixture root")
        }
    }

    var mailbox: URL {
        root.appendingPathComponent("GaoSeries/GaoAction/OcrReturns-v1", isDirectory: true)
    }

    func path(_ name: String) -> URL { root.appendingPathComponent(name) }

    func requestPackage(_ name: String) throws -> URL {
        let saved = try String(contentsOf: path(name + ".request"), encoding: .utf8)
        let url = URL(fileURLWithPath: saved, isDirectory: true).resolvingSymlinksInPath()
        try require(url.path.hasPrefix(root.path + "/"), "request outside fixture")
        return url
    }

    func recordRequest(_ package: URL, _ name: String) throws {
        try write(Data(package.path.utf8), path(name + ".request"))
    }

    func resultPath(requestID: String) -> URL {
        mailbox.appendingPathComponent(requestID.lowercased(), isDirectory: true)
            .appendingPathComponent("result.gaoaction", isDirectory: true)
    }

    func requestData(_ package: URL) throws -> Data {
        try Data(contentsOf: package.appendingPathComponent("manifest.json"))
    }

    func checkTicket(requestID: String, source: String, expiresAt: String, raw: Data) throws {
        try require(UUID(uuidString: requestID)?.uuidString == requestID, "the V1 manifest must retain its native UUID spelling")
        let result = resultPath(requestID: requestID)
        let ticket = result.deletingLastPathComponent().appendingPathComponent("request.json")
        let bytes = try Data(contentsOf: ticket)
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        try require(!bytes.starts(with: [0xEF, 0xBB, 0xBF]) && object?.keys.count == 7, "wrong ticket shape")
        try require(object?["schemaVersion"] as? Int == 1 && object?["action"] as? String == "ocr.files",
                    "wrong ticket version or action")
        try require(object?["requestID"] as? String == requestID && object?["sourceBundleID"] as? String == source &&
                    object?["targetBundleID"] as? String == Self.provider && object?["expiresAt"] as? String == expiresAt &&
                    object?["requestManifestSHA256"] as? String == digest(raw), "ticket not bound to exact native bytes")
    }
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func write(_ data: Data, _ url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw FixtureFailure(description: message) }
}

func rejected(_ message: String, _ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw FixtureFailure(description: "Unexpected acceptance: " + message)
}
