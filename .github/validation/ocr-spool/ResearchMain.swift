import Foundation

@main struct ResearchFixture {
    static func main() throws {
        let fixture = try Fixture()
        // The production package writer supplies its own wall clock when it commits a request.
        var referenceClock: Date? = nil
        let client = ResearchExchangeClient(exchangeRoot: fixture.path("research-exchange"), researchBundleID: Fixture.research,
            providerLookup: { _ in nil }, clock: { referenceClock ?? Date() }, ocrReturns: ResearchOCRReturns(root: fixture.mailbox))
        let source = fixture.path("research-source.png")
        let sourceData = Data("Synthetic source bytes for research.".utf8)
        switch fixture.mode {
        case "prepare":
            try write(sourceData, source)
            let request = try client.prepareOCR(userSelectedFiles: [.init(url: source, documentID: "synthetic-original")],
                                                autoReturn: true)
            let raw = try fixture.requestData(request.packageURL)
            let manifest = try JSONDecoder().decode(GaoActionManifest.self, from: raw)
            try require(request.autoReturnEnabled, "research production request did not publish its ticket")
            try require(manifest.parameters.isEmpty, "research request must preserve omitted default formats")
            try require(manifest.createdAt.contains("."), "research request must preserve the native fractional timestamp")
            try require(manifest.items[0].relativePath.hasPrefix("payload/"), "research request path convention")
            try fixture.checkTicket(requestID: request.requestID, source: Fixture.research, expiresAt: manifest.expiresAt, raw: raw)
            try require(try client.receiveReturnedOCR(requestID: request.requestID) == nil,
                        "research must wait before the provider publishes")
            try fixture.recordRequest(request.packageURL, "research")
            print("PASS research created production outbound journal, fractional timestamp and ticket")
        case "receive":
            let package = try fixture.requestPackage("research")
            let file = package.appendingPathComponent("manifest.json")
            let raw = try fixture.requestData(package)
            let request = try JSONDecoder().decode(GaoActionManifest.self, from: raw)
            let window = try EnvelopeWindow(raw)
            let resultWindow = try EnvelopeWindow(fixture.requestData(fixture.resultPath(requestID: request.requestID)))
            referenceClock = try window.reviewTime(resultWindow)
            try write(raw + Data("\n".utf8), file)
            try rejected("matching decoded request with changed wire digest") {
                _ = try client.receiveReturnedOCR(requestID: request.requestID)
            }
            try write(raw, file)
            try require(try client.loadSession(request.requestID).resultIDs.isEmpty, "tampered request recorded a result")
            guard let returned = try client.receiveReturnedOCR(requestID: request.requestID) else {
                throw FixtureFailure(description: "No research OCR returned")
            }
            try require(!returned.duplicate && !returned.businessApplied && returned.ocrOutputs.count == 2,
                        "research must stage default text and JSON without applying")
            try require(returned.ocrOutputs.allSatisfy { $0.sourceDocumentID == "synthetic-original" &&
                        $0.sourceItemID == request.items[0].id && $0.sourceSHA256 == request.items[0].sha256 },
                        "wrong original research document binding")
            try require(returned.package.manifest.parameters.isEmpty && returned.package.manifest.items.allSatisfy {
                $0.relativePath.hasPrefix("payload/")
            }, "wrong research result envelope or payload convention")
            try require(try client.receiveReturnedOCR(requestID: request.requestID)?.duplicate == true,
                        "research did not suppress repeat receive")
            referenceClock = max(window.expires, resultWindow.expires)
            let resumed = try client.stagedReturnedOCR(requestID: request.requestID)
            try require(resumed?.package.manifest.requestID == returned.package.manifest.requestID &&
                        resumed?.businessApplied == false && resumed?.duplicate == true,
                        "research did not preserve explicit review of previously staged result")
            try require(try Data(contentsOf: source) == sourceData, "research original bytes changed")
            print("PASS research rejected modified request, verified native pending result and resumed private review after expiry")
        default:
            throw FixtureFailure(description: "Unknown research phase")
        }
    }
}
