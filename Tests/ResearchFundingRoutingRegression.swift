import Foundation

@main enum ResearchFundingRoutingRegression {
    static func main() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        for value in ["4.04", "4.4", "4.04.1", "4.12", "5.0"] {
            require(ResearchFundingHandoff.supportsTargetVersion(value), "Expected supported receiver version")
        }
        for value in ["", "4.03", "3.99", "4.x", "4..4", "-4.4", "４.４"] {
            require(!ResearchFundingHandoff.supportsTargetVersion(value), "Malformed/old receiver admitted")
        }
        let id = "original id/&?你好+"
        let route = ResearchFundingHandoff.destination(recordID: id)
        let parts = URLComponents(url: route, resolvingAgainstBaseURL: false)!
        require(parts.scheme == "gaojixu" && parts.host == "research-funding", "Wrong recipient route")
        require(parts.queryItems?.first(where: { $0.name == "id" })?.value == id, "Source ID changed or query injection")
        require(!parts.queryItems!.contains(where: { $0.name == "amount" }), "Deep link can fabricate a payment")
        let old = URL(string: "gaoyanjiu://funding?recordID=original%26id")!
        require(ResearchFundingHandoff.legacyRecordID(from: old) == "original&id", "Legacy ID lost")
        require(ResearchFundingHandoff.legacyRecordID(from: URL(string: "gaoyanjiu://works?recordID=other")!) == nil, "Unrelated link became funding")
        require(ResearchFundingHandoff.protectsTrash(kind: "funding", containsFunding: false), "Missing funding payload became deletable")
        require(ResearchFundingHandoff.protectsTrash(kind: "project", containsFunding: true), "Mismatched funding wrapper became deletable")
        require(!ResearchFundingHandoff.protectsTrash(kind: "project", containsFunding: false), "Unrelated trash blocked")
        print("PASS funding route/receiver version/source ID/read-only trash policy; no application launched")
    }
}
