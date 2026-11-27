import Foundation

/// The two compiler targets share the fixture inputs, not the GaoAction implementation.
@main
struct ResearchOCRReturnInterop {
    private static let researchID = "com.academic-achievement.manager"
    private static let recognized = "OCR transport fixture 12345"
    private static let original = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGP4DwABAQEAsTj2FAAAAABJRU5ErkJggg=="
    )!

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message: message) }
    }

    private static func mailbox(in root: URL) -> URL {
        root.appendingPathComponent("GaoSeries/GaoAction/OcrReturns-v1", isDirectory: true)
    }

    private static func originalURL(in root: URL) -> URL {
        root.appendingPathComponent("synthetic.png")
    }

    private static func researchExchange(in root: URL) -> URL {
        root.appendingPathComponent("Research", isDirectory: true)
    }

    private static func requestURL(_ value: String, in root: URL) throws -> URL {
        let url = URL(fileURLWithPath: value, isDirectory: true)
        let expected = researchExchange(in: root).appendingPathComponent("Outgoing", isDirectory: true)
        try check(url.deletingLastPathComponent().resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path
                    && url.pathExtension == "gaoaction",
                  "The request must come from the isolated Research outbox.")
        return url
    }

    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { throw Failure(message: "Expected scratch directory and operation.") }
        let root = URL(fileURLWithPath: args[0], isDirectory: true)
        try check(root.deletingLastPathComponent().resolvingSymlinksInPath().path == "/private/tmp"
                    && root.lastPathComponent.hasPrefix("gao-research-ocr-interop."),
                  "The bridge requires its isolated scratch directory.")
        #if OCR_RETURN_PROVIDER_FIXTURE
        guard args.count == 3 && args[1] == "publish" else { throw Failure(message: "Expected a Research request to publish.") }
        try publish(in: root, url: requestURL(args[2], in: root))
        #else
        if args.count == 2 && args[1] == "prepare" {
            try prepare(in: root)
        } else if args.count == 3 && args[1] == "receive" {
            try receive(in: root, url: requestURL(args[2], in: root))
        } else {
            throw Failure(message: "Expected prepare or receive.")
        }
        #endif
    }

    #if OCR_RETURN_PROVIDER_FIXTURE
    private static func publish(in root: URL, url: URL) throws {
        let exchange = root.appendingPathComponent("GaoCaoZuo", isDirectory: true)
        let request = try ScreenshotGaoActionTransport.receive(packageURL: url, exchangeRoot: exchange)
        guard let binding = ScreenshotOCRReturnBinding(request), let input = request.stagedItems.first else {
            throw Failure(message: "GaoCaoZuo could not bind the Research request.")
        }
        let returnRoot = mailbox(in: root)
        try check(ScreenshotOCRReturn.isReady(binding, root: returnRoot), "GaoCaoZuo rejected the live Research ticket.")
        try ScreenshotGaoActionTransport.verifyStagedOCR(request)
        try check(try Data(contentsOf: input.url) == original, "GaoCaoZuo staged different source bytes.")

        let ledger = try ScreenshotGaoProcessedRequestStore(root: exchange)
        _ = try ledger.receive(request)
        let sourceID = UUID().uuidString
        let text = root.appendingPathComponent("recognized.txt")
        let json = root.appendingPathComponent("recognized.json")
        try Data(recognized.utf8).write(to: text)
        let artifact: [String: Any] = [
            "schemaVersion": 1,
            "sources": [["id": sourceID, "sha256": input.item.sha256]],
            "pages": [["sourceID": sourceID, "originalSHA256": input.item.sha256, "pageNumber": 1,
                       "status": "completed", "lines": [["text": recognized, "readingOrder": 0]]]]
        ]
        try JSONSerialization.data(withJSONObject: artifact).write(to: json)
        let identity: [String: ScreenshotGaoJSONValue] = [
            "sourceID": .string(sourceID), "sourceItemID": .string(input.item.id), "sourceSHA256": .string(input.item.sha256)
        ]
        var source = identity
        source["pages"] = .array([.object(["pageNumber": .number(1), "status": .string("completed")])])
        source["outputItemIDs"] = .array([.string("text"), .string("json")])
        let outputRows: [ScreenshotGaoJSONValue] = ["text", "json"].map { id in
            var row = identity
            row["resultItemID"] = .string(id)
            row["format"] = .string(id)
            return .object(row)
        }
        let output = try ScreenshotGaoActionWriter.writeResult(
            inReplyTo: request.manifest, status: "completed", items: [
                .init(url: text, uti: "public.utf8-plain-text", id: "text"),
                .init(url: json, uti: "public.json", id: "json")
            ], provenance: [
                "requestManifestSHA256": .string(binding.requestManifestSHA256), "sources": .array([.object(source)]),
                "outputs": .array(outputRows), "exportFailures": .array([])
            ], exchangeRoot: exchange
        )
        let manifest = output.appendingPathComponent("manifest.json")
        let digest = ScreenshotFileSafety.digest(try Data(contentsOf: manifest))
        let slot = returnRoot.appendingPathComponent(binding.requestID.lowercased(), isDirectory: true)
        let result = slot.appendingPathComponent("result.gaoaction", isDirectory: true)
        guard let waiting = ledger.lookup(binding.requestID) else { throw Failure(message: "Provider ledger is missing the request.") }
        try check(ScreenshotOCRReturn.publish(waiting, resultURL: output, root: returnRoot) == .unavailable,
                  "GaoCaoZuo returned a result before the approval transitions.")
        try check(!FileManager.default.fileExists(atPath: result.path), "A premature result reached the mailbox.")
        _ = try ledger.transition(requestID: binding.requestID, to: .approved)
        _ = try ledger.transition(requestID: binding.requestID, to: .executing)
        let completed = try ledger.transition(requestID: binding.requestID, to: .completed,
                                             resultPackageName: output.lastPathComponent, resultManifestSHA256: digest)
        try check(ScreenshotOCRReturn.publish(completed, resultURL: output, root: returnRoot) == .published,
                  "GaoCaoZuo failed to publish the approved result.")
        try check(ScreenshotOCRReturn.publish(completed, resultURL: output, root: returnRoot) == .published,
                  "GaoCaoZuo retry did not recognize its existing result.")
        try check(try Data(contentsOf: result.appendingPathComponent("manifest.json")) == Data(contentsOf: manifest),
                  "Published bytes differ from the provider's own saved result.")
        print("GaoCaoZuo validated the Research request and published exactly one approved result.")
    }
    #else
    private static func client(in root: URL, clock: @escaping () -> Date = Date.init) -> ResearchExchangeClient {
        ResearchExchangeClient(exchangeRoot: researchExchange(in: root), researchBundleID: researchID,
                               providerLookup: { _ in nil }, clock: clock,
                               ocrReturns: ResearchOCRReturns(root: mailbox(in: root)))
    }

    private static func prepare(in root: URL) throws {
        let source = originalURL(in: root)
        try original.write(to: source)
        let research = client(in: root)
        let request = try research.prepareOCR(userSelectedFiles: [.init(url: source, documentID: "fixture")],
                                              outputs: ["text", "json"], autoReturn: true)
        try check(request.autoReturnEnabled, "Research failed to publish an explicit ticket.")
        try check(try research.receiveReturnedOCR(requestID: request.requestID) == nil,
                  "Research found a result before the provider ran.")
        print(request.packageURL.path)
    }

    private static func receive(in root: URL, url: URL) throws {
        let requestID = url.deletingPathExtension().lastPathComponent
        let research = client(in: root)
        guard let result = try research.receiveReturnedOCR(requestID: requestID),
              let text = result.ocrOutputs.first(where: { $0.uti == "public.utf8-plain-text" }),
              let json = result.ocrOutputs.first(where: { $0.uti == "public.json" }) else {
            throw Failure(message: "Research did not stage the two provider outputs.")
        }
        try check(!result.businessApplied && !result.duplicate && result.ocrOutputs.count == 2,
                  "Research did not stage a single result for explicit review.")
        try check(result.package.manifest.inReplyTo == requestID && result.package.manifest.parameters.isEmpty,
                  "The provider changed the request UUID spelling or result parameters.")
        try check(try Data(contentsOf: text.localCopy) == Data(recognized.utf8), "Recognized text failed its round trip.")
        try check(json.pages.count == 1 && json.pages[0].status == "completed", "JSON page provenance failed its round trip.")
        try check(try research.receiveReturnedOCR(requestID: requestID)?.duplicate == true,
                  "Research did not reuse its exact private stage.")
        let later = client(in: root, clock: { Date().addingTimeInterval(121) })
        try check(try later.stagedReturnedOCR(requestID: requestID)?.ocrOutputs.count == 2,
                  "A local review could not reopen after transport expiry.")
        try check(try Data(contentsOf: originalURL(in: root)) == original, "The original was changed.")
        print("Research staged the provider result for review and reopened it after transport expiry.")
    }
    #endif
}
