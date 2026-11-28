import Foundation

@main struct OperationsFixture {
    static func main() throws {
        let fixture = try Fixture()
        try require(fixture.mode == "publish", "Unknown operations phase")
        let exchange = fixture.path("operations-exchange")
        let ledger = try ScreenshotGaoProcessedRequestStore(root: exchange)
        for label in ["files", "research"] {
            let requestURL = try fixture.requestPackage(label)
            let manifestURL = requestURL.appendingPathComponent("manifest.json")
            let original = try fixture.requestData(requestURL)
            let window = try EnvelopeWindow(original)
            let now = window.resultTime
            try require(now < window.expires, "fixture write instant must be inside original validity window")
            print("Inspecting \(label) production request with duration \(window.expires.timeIntervalSince(window.created)) seconds")
            try rejected("envelope created in the future") {
                _ = try ScreenshotGaoActionTransport.receive(packageURL: requestURL, exchangeRoot: exchange,
                                                            now: window.created.addingTimeInterval(-0.001))
            }
            let request = try ScreenshotGaoActionTransport.receive(packageURL: requestURL, exchangeRoot: exchange, now: now)
            let requestID = request.manifest.requestID
            guard let binding = ScreenshotOCRReturnBinding(request), let input = request.manifest.items.first else {
                throw FixtureFailure(description: "No production OCR request binding for " + label)
            }
            try require(ScreenshotOCRReturn.isReady(binding, root: fixture.mailbox, now: now),
                        "provider cannot validate the peer's ticket")
            try write(original + Data("\n".utf8), manifestURL)
            let edited = try ScreenshotGaoActionTransport.receive(packageURL: requestURL, exchangeRoot: exchange, now: now)
            try require(edited.manifest == request.manifest && edited.manifestSHA256 != request.manifestSHA256,
                        "fixture must change wire bytes only")
            guard let editedBinding = ScreenshotOCRReturnBinding(edited) else {
                throw FixtureFailure(description: "Modified request must remain syntactically valid")
            }
            try require(!ScreenshotOCRReturn.isReady(editedBinding, root: fixture.mailbox, now: now),
                        "modified original manifest matched the ticket")
            var differentNonce = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            differentNonce["nonce"] = Data(repeating: 0x99, count: 32).base64EncodedString()
            try write(try JSONSerialization.data(withJSONObject: differentNonce), manifestURL)
            let nonceChanged = try ScreenshotGaoActionTransport.receive(packageURL: requestURL, exchangeRoot: exchange, now: now)
            guard let nonceBinding = ScreenshotOCRReturnBinding(nonceChanged) else {
                throw FixtureFailure(description: "Request with a different nonce must decode")
            }
            try require(nonceBinding.requestID == requestID && nonceChanged.manifest.nonce != request.manifest.nonce &&
                        !ScreenshotOCRReturn.isReady(nonceBinding, root: fixture.mailbox, now: now),
                        "ticket did not bind original nonce bytes")
            try write(original, manifestURL)

            let recognized = fixture.path(label + "-ocr.txt")
            try write(Data(Fixture.items.utf8), recognized)
            let producer = UUID().uuidString
            let source: [String: ScreenshotGaoJSONValue] = [
                "sourceID": .string(producer), "sourceItemID": .string(input.id), "sourceSHA256": .string(input.sha256)
            ]
            var outputs = [("text", ScreenshotGaoOutgoingFile(url: recognized, uti: "public.utf8-plain-text"))]
            if label == "research" {
                let url = fixture.path(label + "-ocr.json")
                let data = try JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 1,
                    "sources": [["id": producer, "sha256": input.sha256]],
                    "pages": [["sourceID": producer, "originalSHA256": input.sha256, "pageNumber": 1,
                               "status": "completed", "lines": [["text": Fixture.items]]]]
                ])
                try write(data, url)
                outputs.append(("json", ScreenshotGaoOutgoingFile(url: url, uti: "public.json")))
            }
            let pages: [ScreenshotGaoJSONValue] = [.object(["pageNumber": .number(1), "status": .string("completed"),
                                                           "elapsedSeconds": .number(0), "lineCount": .number(1)])]
            var sourceRow = source
            sourceRow["outputItemIDs"] = .array(outputs.map { .string($0.1.id) })
            sourceRow["pages"] = .array(pages)
            let resultRows: [ScreenshotGaoJSONValue] = outputs.map { output in
                let (format, item) = output
                var row = source
                row["resultItemID"] = .string(item.id)
                row["format"] = .string(format)
                return .object(row)
            }
            let provenance: [String: ScreenshotGaoJSONValue] = [
                "requestManifestSHA256": .string(request.manifestSHA256),
                "engine": .string("Apple Vision VNRecognizeTextRequest"),
                "engineRevision": .number(1), "networkUsed": .bool(false), "exportFailures": .array([]),
                "sources": .array([.object(sourceRow)]), "outputs": .array(resultRows)
            ]
            let resultURL = try ScreenshotGaoActionWriter.writeResult(inReplyTo: request.manifest, status: "completed",
                items: outputs.map { $0.1 }, provenance: provenance, exchangeRoot: exchange, now: now)
            let resultRaw = try fixture.requestData(resultURL)
            let pending = try ledger.receive(request, now: now).record
            let destination = fixture.resultPath(requestID: requestID)
            try require(ScreenshotOCRReturn.publish(pending, resultURL: resultURL, root: fixture.mailbox,
                                                    clock: { now }) == .unavailable &&
                        !FileManager.default.fileExists(atPath: destination.path), "an unapproved record was published")
            _ = try ledger.transition(requestID: requestID, to: .approved, now: now)
            _ = try ledger.transition(requestID: requestID, to: .executing, now: now)
            let completed = try ledger.transition(requestID: requestID, to: .completed,
                resultPackageName: resultURL.lastPathComponent, now: now, resultManifestSHA256: digest(resultRaw))
            try require(ScreenshotOCRReturn.publish(completed, resultURL: resultURL, root: fixture.mailbox,
                                                    clock: { now }) == .published, "provider failed to publish " + label)
            try require(try fixture.requestData(destination) == resultRaw, "provider rewrote the result envelope")
            try require(ScreenshotOCRReturn.publish(completed, resultURL: resultURL, root: fixture.mailbox,
                                                    clock: { now }) == .published, "identical retry was rejected")
            try require(try fixture.requestData(destination) == resultRaw, "identical retry changed the result")
            try require(ScreenshotOCRReturn.publish(completed, resultURL: resultURL, root: fixture.mailbox,
                                                    clock: { window.expires }) == .expired,
                        "return was accepted on the exact original expiry boundary")
            print("PASS operations validated \(label) ticket, denied pre-approval and changed bytes, and published identical retries")
            if label == "research" {
                try assertFractionalResultWriter(from: request.manifest, items: outputs.map { $0.1 }, provenance: provenance,
                                                 fixture: fixture, exchange: exchange, near: now)
            }
        }
    }

    private static func assertFractionalResultWriter(from request: ScreenshotGaoActionManifest,
                                                     items: [ScreenshotGaoOutgoingFile],
                                                     provenance: [String: ScreenshotGaoJSONValue], fixture: Fixture,
                                                     exchange: URL, near instant: Date) throws {
        let second = floor(instant.timeIntervalSince1970) + 2
        let offsets = [0.0001, 0.00049, 0.0005, 0.00051, 0.0009, 0.2499999, 0.99949, 0.99951, 0.9999]
        for offset in offsets {
            let clock = Date(timeIntervalSince1970: second + offset)
            let result: URL
            do {
                result = try ScreenshotGaoActionWriter.writeResult(inReplyTo: request, status: "completed", items: items,
                                                                  provenance: provenance, exchangeRoot: exchange, now: clock)
            } catch {
                let unquantized = ScreenshotGaoActionContract.timestamp(clock, fractional: true)
                let roundTrip = ScreenshotGaoActionContract.date(unquantized)
                let excess = roundTrip?.timeIntervalSince(clock)
                throw FixtureFailure(description: "Production OCR writer rejected offset \(offset) within the second. "
                    + "Unquantized formatter returned \(unquantized), delta \(String(describing: excess)) seconds. \(error)")
            }
            let window = try EnvelopeWindow(fixture.requestData(result))
            try require(window.created <= clock && window.expires.timeIntervalSince(window.created) <= 120,
                        "invalid future creation or excessive TTL at fractional offset \(offset)")
        }
        let creation = Date(timeIntervalSince1970: second + 0.125)
        let immediate = Date(timeIntervalSince1970: second + 0.1259)
        var sameSecondRequest = request
        sameSecondRequest.createdAt = ScreenshotGaoActionContract.timestamp(creation, fractional: true)
        sameSecondRequest.expiresAt = ScreenshotGaoActionContract.timestamp(creation.addingTimeInterval(120), fractional: true)
        let reply = try ScreenshotGaoActionWriter.writeResult(inReplyTo: sameSecondRequest, status: "completed", items: items,
                                                             provenance: provenance, exchangeRoot: exchange, now: immediate)
        let window = try EnvelopeWindow(fixture.requestData(reply))
        try require(window.created >= creation && window.created <= immediate,
                    "same-second response cannot be earlier than its fractional request or later than the supplied clock")
        print("PASS production OCR result writer at \(offsets.count) sub-millisecond and second-boundary offsets and an immediate same-second response")
    }
}
