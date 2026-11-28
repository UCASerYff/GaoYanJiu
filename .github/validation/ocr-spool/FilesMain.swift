import Foundation

@main struct FilesFixture {
    static let requestID = UUID(uuidString: "ABCDEF12-1111-4222-8333-444444444444")!

    static func main() throws {
        let fixture = try Fixture()
        let exchange = fixture.path("files-exchange")
        let journal = try GaoOutgoingJournal(exchangeRoot: exchange)
        let source = fixture.path("files-source.png")
        switch fixture.mode {
        case "prepare":
            try write(Data("Synthetic source bytes for files.".utf8), source)
            let item = GaoOutgoingFile(url: source, uti: "public.png")
            let package = try GaoActionWriter.writeRequest(action: "ocr.files", items: [item],
                parameters: ["outputs": .array([.string("text")])], targetBundleID: Fixture.provider,
                exchangeRoot: exchange, now: Fixture.start, requestID: requestID)
            let reference = GaoActionReference(id: "original", kind: "file", fileURL: source.absoluteString,
                displayName: "Synthetic source", declaredIdentity: .init(volumeUUID: nil, device: nil, inode: nil,
                                                                           byteCount: nil, modifiedAt: nil))
            let binding = GaoOutgoingSourceBinding(itemID: item.id, originalReference: reference)
            let session = try journal.registerOutgoing(packageURL: package, expectedTargetBundleID: Fixture.provider,
                                                       bindings: [binding], now: Fixture.start)
            _ = try OCRReturnMailbox.publishTicket(for: session, packageURL: package, exchangeRoot: exchange,
                                                  mailboxRoot: fixture.mailbox, now: Fixture.start)
            let raw = try fixture.requestData(package)
            let request = try GaoActionTransport.decodeManifest(raw)
            try require(!request.createdAt.contains("."), "files request needs whole seconds")
            try require(request.items[0].relativePath.hasPrefix("payload/") == false, "files request path convention")
            try fixture.checkTicket(requestID: request.requestID, source: Fixture.files,
                                    expiresAt: request.expiresAt, raw: raw)
            let waiting = try OCRReturnMailbox.scan(exchangeRoot: exchange, mailboxRoot: fixture.mailbox, now: Fixture.start)
            try require(waiting.pending && waiting.results.isEmpty, "files must wait before the provider publishes")
            try fixture.recordRequest(package, "files")
            print("PASS files created production outbound journal, whole-second request and ticket")
        case "receive":
            let raw = try fixture.requestData(fixture.requestPackage("files"))
            let request = try GaoActionTransport.decodeManifest(raw)
            let window = try EnvelopeWindow(raw)
            let resultWindow = try EnvelopeWindow(fixture.requestData(fixture.resultPath(requestID: request.requestID)))
            let reviewTime = try window.reviewTime(resultWindow)
            let noResult = try OCRReturnMailbox.scan(exchangeRoot: exchange, mailboxRoot: fixture.mailbox,
                                                     now: window.expires)
            try require(noResult.results.isEmpty, "expired original request cannot yield a new review")
            let scan = try OCRReturnMailbox.scan(exchangeRoot: exchange, mailboxRoot: fixture.mailbox, now: reviewTime)
            guard let candidate = scan.results.first else { throw FixtureFailure(description: "No file OCR returned") }
            try require(scan.results.count == 1 && scan.issues.isEmpty && candidate.requestID == request.requestID,
                        "wrong files result binding")
            try require(candidate.sources.count == 1 && candidate.sources[0].itemID == request.items[0].id &&
                        candidate.sources[0].sha256 == request.items[0].sha256 &&
                        candidate.sources[0].originalURL?.path == source.path, "wrong original file binding")
            try require(try GaoOutgoingJournal.returnSnapshot(exchangeRoot: exchange).results.isEmpty,
                        "polling recorded an unreviewed result")
            try rejected("unreviewed result digest") {
                _ = try OCRReturnMailbox.review(requestID: request.requestID, expectedDigest: String(repeating: "0", count: 64),
                                               exchangeRoot: exchange, mailboxRoot: fixture.mailbox, now: reviewTime)
            }
            let reviewed = try OCRReturnMailbox.review(requestID: candidate.requestID, expectedDigest: candidate.manifestSHA256,
                                                       exchangeRoot: exchange, mailboxRoot: fixture.mailbox, now: reviewTime)
            try require(reviewed.manifest.parameters.isEmpty && reviewed.stagedItems.count == 1 &&
                        !reviewed.stagedItems[0].item.relativePath.hasPrefix("payload/"), "wrong files result format")
            try require(try String(contentsOf: reviewed.stagedItems[0].url, encoding: .utf8) == Fixture.items,
                        "wrong returned files text")
            let first = try journal.receiveResult(reviewed, now: reviewTime)
            let repeatReceipt = try journal.receiveResult(reviewed, now: reviewTime)
            try require(!first.isDuplicate && first.record.phase == .received && repeatReceipt.isDuplicate,
                        "files result registration is not pending and idempotent")
            try require(try Data(contentsOf: source) == Data("Synthetic source bytes for files.".utf8),
                        "files original bytes changed")
            print("PASS files read production spool, bound original, staged after explicit digest review and suppressed duplicates")
        default:
            throw FixtureFailure(description: "Unknown files phase")
        }
    }
}
