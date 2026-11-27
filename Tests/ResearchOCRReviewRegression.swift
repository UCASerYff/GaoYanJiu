import Foundation
import PDFKit

#if !LIBRARY_LOAD_SAFETY_TEST
#error("Use scripts/test_library_load.sh --case ocr-auto-return.")
#endif

@MainActor
extension LibraryLoadSafetyRegression {
    private final class ReturnedOCRClock {
        var offset: TimeInterval = 0
        var now: Date { Date().addingTimeInterval(offset) }
    }

    private static func fixtureTwoPagePDF() -> Data {
        func stream(_ text: String) -> String {
            let commands = "BT /F1 16 Tf 40 340 Td (\(text)) Tj ET"
            return "<< /Length \(commands.utf8.count) >>\nstream\n\(commands)\nendstream"
        }
        let resources = "/Resources << /Font << /F1 7 0 R >> >>"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 2 /Kids [3 0 R 4 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] \(resources) /Contents 5 0 R >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] \(resources) /Contents 6 0 R >>",
            stream("Original page one"), stream("Original page two"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var text = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(text.utf8.count)
            text += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = text.utf8.count
        text += "xref\n0 8\n0000000000 65535 f \n"
        for offset in offsets { text += String(format: "%010ld 00000 n \n", offset) }
        text += "trailer\n<< /Root 1 0 R /Size 8 >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(text.utf8)
    }

    private static func requireOCRState(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure(description: message)
    }

    static func automaticOCRReview() async throws {
        try await runAsync("review-after-reopen", category: "automatic OCR review") { directory in
            let fixture = try ocrFixture(directory)
            let originalBytes = fixtureTwoPagePDF()
            let input = directory.appendingPathComponent("synthetic-original.pdf")
            try write(originalBytes, input)
            let store = fixture.store
            let folderID = fixture.initial.documentFolders[0].id
            let imported = try await store.importDocuments(from: [input], into: folderID)
            try require(imported == 1, "The synthetic PDF did not import")
            let original = try unwrap(store.managedDocuments.first(where: { $0.fileExtension == "pdf" }),
                                      "The managed PDF is missing")
            let managedURL = store.managedDocumentURL(original)
            let beforeIDs = Set(store.managedDocuments.map(\.id))
            let beforeLibrary = try Data(contentsOf: fixture.disk.libraryURL)
            let clock = ReturnedOCRClock()
            let mailbox = ResearchOCRReturns(root: directory.appendingPathComponent("OcrReturns-v1", isDirectory: true))
            let client = ResearchExchangeClient(exchangeRoot: ResearchExchangePaths.root,
                researchBundleID: ResearchOCRReturns.sourceBundleID, providerLookup: { _ in nil },
                clock: { clock.now }, ocrReturns: mailbox)
            let library = store.documentLibrary
            library.exchangeClientOverride = client
            let prepared = try client.prepareOCR(
                userSelectedFiles: [.init(url: managedURL, documentID: original.id)], outputs: ["text"], autoReturn: true)
            try require(prepared.autoReturnEnabled, "The explicit OCR request did not register a private return slot")
            let session = try client.loadSession(prepared.requestID)
            let ticket = try unwrap(session.ocrAutoReturn, "The OCR return ticket was not recorded")
            let binding = try unwrap(session.sources.first, "The OCR request did not bind the original")
            let uniqueText = "synthetic second OCR page indexed only after approval"
            let output = directory.appendingPathComponent("recognized.txt")
            try write(Data(uniqueText.utf8), output)
            let providerSourceID = UUID().uuidString
            let sourceIdentity: [String: GaoJSONValue] = ["sourceID": .string(providerSourceID),
                "sourceItemID": .string(binding.itemID), "sourceSHA256": .string(binding.sha256)]
            var source = sourceIdentity
            source["outputItemIDs"] = .array([.string("text-output")])
            source["pages"] = .array([
                .object(["pageNumber": .number(1), "status": .string("failed")]),
                .object(["pageNumber": .number(2), "status": .string("completed"), "text": .string(uniqueText)]),
            ])
            var outputMapping = sourceIdentity
            outputMapping["resultItemID"] = .string("text-output")
            outputMapping["format"] = .string("text")
            let manifest = GaoActionManifest(kind: "result", sourceBundleID: ResearchOCRReturns.targetBundleID,
                targetBundleID: ResearchOCRReturns.sourceBundleID, action: ResearchExternalAction.ocrFiles.rawValue,
                items: [.init(id: "text-output", relativePath: "payload/recognized.txt", uti: "public.utf8-plain-text",
                              byteCount: 0, sha256: String(repeating: "0", count: 64))],
                inReplyTo: prepared.requestID, status: "partial", provenance: [
                    "requestManifestSHA256": .string(ticket.requestManifestSHA256), "engine": .string("FixtureOCR"),
                    "engineVersion": .string("1"), "languages": .array([.string("en-US")]),
                    "sources": .array([.object(source)]), "outputs": .array([.object(outputMapping)]),
                    "exportFailures": .array([.string("Synthetic first page missing OCR")]),
                ])
            let package = try GaoActionPackageWriter().write(manifest: manifest, files: ["text-output": output],
                outgoingRoot: directory.appendingPathComponent("Provider", isDirectory: true))
            let mailboxResult = mailbox.root.appendingPathComponent(prepared.requestID.lowercased(), isDirectory: true)
                .appendingPathComponent("result.gaoaction", isDirectory: true)
            try FileManager.default.moveItem(at: package, to: mailboxResult)

            // The known request is waiting but the workbench has not become visible.
            library.trackOCRReturn(prepared)
            try await Task.sleep(nanoseconds: 80_000_000)
            try require(try client.loadSession(prepared.requestID).ocrReturn == nil, "A hidden workbench consumed OCR")
            library.setOCRReturnActive(true)
            defer { library.setOCRReturnActive(false) }
            try await requireOCRState("The visible workbench did not queue the result") { library.pendingOCRReturns.count == 1 }
            try require(library.pendingOCRReturns(for: original.id).count == 1
                        && library.pendingExchangeResultReview == nil, "Receipt opened UI or did not attach to its original")
            try require(try Data(contentsOf: fixture.disk.libraryURL) == beforeLibrary
                        && store.documents(in: folderID, search: uniqueText).isEmpty,
                        "Receipt entered the library or index before approval")
            library.setOCRReturnActive(false)
            clock.offset = 180

            let reopened = PaperStore(repository: fixture.disk)
            let reopenedLibrary = reopened.documentLibrary
            reopenedLibrary.exchangeClientOverride = client
            reopenedLibrary.setOCRReturnActive(true)
            defer { reopenedLibrary.setOCRReturnActive(false) }
            try await requireOCRState("The queued result did not survive reopening and transport expiry") {
                reopenedLibrary.pendingOCRReturns(for: original.id).count == 1
            }
            let pending = try unwrap(reopenedLibrary.pendingOCRReturns.first, "The durable queue row is absent")
            // An already accepted receipt remains inspectable if the original later moves.
            // Move the fixture back before exercising the real confirmed transaction.
            do {
                let heldOriginal = directory.appendingPathComponent("held-original.pdf")
                try FileManager.default.moveItem(at: managedURL, to: heldOriginal)
                defer { try? FileManager.default.moveItem(at: heldOriginal, to: managedURL) }
                try await reopenedLibrary.openPendingOCRReview(pending)
                let inspection = try unwrap(reopenedLibrary.pendingExchangeResultReview, "A moved source hid an accepted OCR result")
                try require(!inspection.canApply && !inspection.result.ocrSourcesCurrent
                            && inspection.ocrReviewPages["text-output"]?.first(where: { $0.pageNumber == 2 })?.text == uniqueText,
                            "An unavailable source should permit text inspection only")
                try await mustReject("A missing source permitted an explicitly approved import") {
                    _ = try await reopenedLibrary.applyExchangeResult(inspection, userApproved: true)
                }
                reopenedLibrary.pendingExchangeResultReview = nil
                try require(reopenedLibrary.pendingOCRReturns.count == 1
                            && reopened.documents(in: folderID, search: uniqueText).isEmpty,
                            "An unavailable source consumed the pending receipt or updated the index")
            }
            try await reopenedLibrary.openPendingOCRReview(pending)
            let review = try unwrap(reopenedLibrary.pendingExchangeResultReview, "The staged result did not open")
            let reviewedPages = review.ocrReviewPages["text-output"] ?? []
            try require(review.canApply && review.requiresExplicitReview && review.result.package.manifest.status == "partial"
                        && reviewedPages.first(where: { $0.pageNumber == 2 })?.text == uniqueText,
                        "The result lost its explicit review gate, partial status, page or text")
            let validatedOriginal = try unwrap(VerifiedSourcePDF.read(at: managedURL, expectedSHA256: binding.sha256),
                "The bound PDF bytes did not pass the source preview check")
            try require(validatedOriginal.pageCount == 2 && validatedOriginal.data == originalBytes,
                        "The verified preview points to the wrong PDF")
            try require(PDFDocument(data: validatedOriginal.data)?.page(at: 1)?.string?.contains("Original page two") == true,
                        "The checked original does not contain the requested second page")
            try require(VerifiedSourcePDF.read(at: managedURL, expectedSHA256: String(repeating: "0", count: 64)) == nil,
                        "The review viewer accepted a mismatching source hash")
            try await mustReject("An unapproved result imported") {
                _ = try await reopenedLibrary.applyExchangeResult(review, userApproved: false)
            }
            reopenedLibrary.pendingExchangeResultReview = nil
            try require(Set(reopened.managedDocuments.map(\.id)) == beforeIDs
                        && reopened.documents(in: folderID, search: uniqueText).isEmpty
                        && reopenedLibrary.pendingOCRReturns.count == 1,
                        "Opening review or declining it changed the library")
            try await reopenedLibrary.openPendingOCRReview(pending)
            let reopenedReview = try unwrap(reopenedLibrary.pendingExchangeResultReview, "Closing review lost the queued result")
            let outcome = try await reopenedLibrary.applyExchangeResult(reopenedReview, userApproved: true)
            try require(outcome.importedCount == 1 && reopenedLibrary.pendingOCRReturns.isEmpty,
                        "Confirmed OCR did not commit and clear the pending queue")
            let searched = reopened.documents(in: folderID, search: uniqueText)
            try require(searched.count == 1 && searched[0].id != original.id
                        && reopened.documentRevision(for: searched[0].id)?.originalDocumentID == original.id,
                        "The index did not point to a new derivative linked to the original")
            try require(try Data(contentsOf: managedURL) == originalBytes,
                        "Confirmed OCR changed the original PDF's bytes")
        }
    }
}
