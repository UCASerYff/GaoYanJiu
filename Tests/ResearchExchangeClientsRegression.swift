import AppKit
import Foundation
import CryptoKit

// Isolated consumer-contract fixtures. Fake app manifests do not prove an
// installed provider, GUI permission, real OCR engine or editing end-to-end.
@main
struct ResearchExchangeClientsRegression {
    static let researchID = "com.academic-achievement.manager"
    static let fixedNow = GaoActionISO8601.date("2026-10-12T12:00:00Z")!
    static let fm = FileManager.default
    static var checks = 0

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: "FixtureFailure", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }

    static func fails(_ label: String, expected: ResearchExchangeClientError? = nil, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch {
            if let expected { try expect((error as? ResearchExchangeClientError) == expected, label + " wrong error: " + String(describing: error)) }
            checks += 1
            return
        }
        throw NSError(domain: "FixtureFailure", code: 2, userInfo: [NSLocalizedDescriptionKey: label + " unexpectedly succeeded"])
    }

    static func write(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func fakeProvider(at root: URL, action: ResearchExternalAction, appVersion: String = "1.00",
                             capabilityVersion: String = "1.00", parameterProperties: [String: GaoJSONValue] = [:]) throws -> URL {
        let app = root.appendingPathComponent(UUID().uuidString + ".app")
        let info: [String: Any] = ["CFBundleIdentifier": action.providerBundleID, "CFBundleShortVersionString": appVersion,
                                   "CFBundlePackageType": "APPL", "CFBundleExecutable": "FakeFixture"]
        try write(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), to: app.appendingPathComponent("Contents/Info.plist"))
        let manifest: GaoJSONValue = .object([
            "schemaVersion": .number(1), "bundleID": .string(action.providerBundleID), "appVersion": .string(capabilityVersion),
            "actions": .object([action.rawValue: .object([
                "parameters": .object(["type": .string("object"), "properties": .object(parameterProperties), "additionalProperties": .bool(false)]),
                "selectionModes": .array([.string("references")])
            ])])
        ])
        try write(JSONEncoder().encode(manifest), to: app.appendingPathComponent("Contents/Resources/GaoCapabilities.json"))
        return app
    }

    static func result(root: URL, request: ResearchPreparedExchange, action: ResearchExternalAction,
                       status: String, outputFiles: [URL] = [], references: [GaoActionReference] = [],
                       provenance: [String: GaoJSONValue], sourceID: String? = nil,
                       outputUTIs: [String]? = nil) throws -> URL {
        let items = outputFiles.enumerated().map { index, url in
            GaoActionItem(id: "output-\(index)", relativePath: "payload/output-\(index).\(url.pathExtension)",
                          uti: outputUTIs?[index] ?? "public.plain-text", byteCount: 0, sha256: String(repeating: "0", count: 64))
        }
        let template = GaoActionManifest(kind: "result", sourceBundleID: sourceID ?? action.providerBundleID,
                                         targetBundleID: researchID, action: action.rawValue,
                                         items: items, references: references, inReplyTo: request.requestID,
                                         status: status, provenance: provenance)
        let package = try GaoActionPackageWriter().write(manifest: template,
                                                        files: Dictionary(uniqueKeysWithValues: zip(items.map(\.id), outputFiles)), outgoingRoot: root)
        let manifestURL = package.appendingPathComponent("manifest.json")
        var manifest = try JSONDecoder().decode(GaoActionManifest.self, from: Data(contentsOf: manifestURL))
        manifest.createdAt = "2026-10-12T12:00:00Z"
        manifest.expiresAt = "2026-10-12T12:02:00Z"
        manifest.nonce = Data(repeating: 0, count: 32).base64EncodedString()
        try write(JSONEncoder().encode(manifest), to: manifestURL)
        return package
    }

    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        do { try runFixtures() }
        catch {
            fputs("Client fixture stopped after \(checks) checks: \(String(describing: error))\n", stderr)
            exit(1)
        }
    }

    static func runFixtures() throws {
        guard let argument = CommandLine.arguments.dropFirst().first else { fatalError("explicit fixture root required") }
        let root = URL(fileURLWithPath: argument, isDirectory: true).resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let client = ResearchExchangeClient(exchangeRoot: root.appendingPathComponent("Exchange"), researchBundleID: researchID,
                                            providerLookup: { _ in nil }, clock: { fixedNow })
        try expect(!client.availability(for: .ocrFiles).isAvailable, "missing provider must be unavailable")

        let provider = try fakeProvider(at: root, action: .chooseFiles, parameterProperties: ["multiple": .object(["type": .string("boolean")])])
        let capable = ResearchExchangeClient(exchangeRoot: root.appendingPathComponent("ProviderFixture"), researchBundleID: researchID,
                                             providerLookup: { _ in provider })
        try expect(capable.availability(for: .chooseFiles, parameters: ["multiple": .bool(true)]).isAvailable, "explicit matching action/schema")
        try expect(!capable.availability(for: .chooseFiles, parameters: ["multiple": .string("true")]).isAvailable, "typed capability mismatch")
        try expect(!capable.availability(for: .chooseFiles, parameters: ["allowedUTIs": .array([.string("com.adobe.pdf")])]).isAvailable, "undeclared option disabled")
        let staleProvider = try fakeProvider(at: root, action: .chooseFiles, capabilityVersion: "2.00")
        let stale = ResearchExchangeClient(exchangeRoot: root.appendingPathComponent("StaleProviderFixture"), researchBundleID: researchID,
                                           providerLookup: { _ in staleProvider })
        try expect(!stale.availability(for: .chooseFiles).isAvailable, "manifest and installed app versions must agree")
        let choose = try client.prepareFileSelection()
        let export = root.appendingPathComponent("manual-export.gaoaction")
        try client.exportFallback(choose, to: export)
        let exportMode = (try fm.attributesOfItem(atPath: export.path)[.posixPermissions] as? NSNumber)?.intValue
        try expect(exportMode == 0o700, "exported package must remain private")

        let selected = root.appendingPathComponent("selected.txt")
        try write(Data("hello\n".utf8), to: selected)
        let reference = try GaoActionReference.capture(at: selected, kind: "file")
        let chooseResult = try result(root: root.appendingPathComponent("ProviderOutgoing"), request: choose, action: .chooseFiles,
                                      status: "completed", references: [reference], provenance: ["workflowState": .string("selected")])
        let receivedSelection = try client.receiveResult(at: chooseResult)
        try expect(receivedSelection.selectedReferences.count == 1 && !receivedSelection.sourceIsAuthenticated, "selection declarations are not authenticated")
        try expect(!receivedSelection.businessApplied, "received files.choose is not a committed import")
        let selectionReceipt = try client.markResultApplied(requestID: choose.requestID, resultID: receivedSelection.package.manifest.requestID,
                                                           importedDocumentIDs: ["imported-selection"], receiptID: "journal-receipt-selection")
        let repeatedReceipt = try client.markResultApplied(requestID: choose.requestID, resultID: receivedSelection.package.manifest.requestID,
                                                          importedDocumentIDs: ["imported-selection"], receiptID: "journal-receipt-selection")
        try expect(selectionReceipt == repeatedReceipt, "business commit receipt is idempotent")
        try expect(try client.receiveResult(at: chooseResult).businessApplied, "committed result is distinct from duplicate receipt")
        try fails("business receipt cannot change documents", expected: .resultMismatch) {
            _ = try client.markResultApplied(requestID: choose.requestID, resultID: receivedSelection.package.manifest.requestID,
                                            importedDocumentIDs: ["other-document"], receiptID: "journal-receipt-selection")
        }
        let verified = try client.verifySelectedReference(reference)
        try expect(try Data(contentsOf: verified.localCopy) == Data("hello\n".utf8), "selected reference copied after local verification")
        var unknown = reference; unknown.declaredIdentity = .init(); unknown.sha256 = nil
        try fails("unknown reference needs local panel", expected: .requiresLocalSelection) { _ = try client.verifySelectedReference(unknown) }
        _ = try client.verifySelectedReference(unknown, userSelectedURL: selected)
        var conflicting = reference; conflicting.sha256 = String(repeating: "f", count: 64)
        try fails("reference summary conflict", expected: .sourceChanged) { _ = try client.verifySelectedReference(conflicting) }
        let link = root.appendingPathComponent("linked.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: selected)
        unknown.fileURL = link.absoluteString
        try fails("linked reference rejected", expected: .requiresLocalSelection) { _ = try client.verifySelectedReference(unknown, userSelectedURL: link) }

        let scope = try GaoActionReference.capture(at: root, kind: "directory")
        let scopedChoose = try client.prepareFileSelection(targetFolderID: "folder-A", sourceScope: scope)
        let scopedSession = try client.loadSession(scopedChoose.requestID)
        try expect(scopedSession.targetFolderID == "folder-A" && scopedSession.sourceScope == scope, "files.choose persists local target and source context")
        let scopedManifest = try JSONDecoder().decode(GaoActionManifest.self, from: Data(contentsOf: scopedChoose.packageURL.appendingPathComponent("manifest.json")))
        try expect(scopedManifest.parameters["targetFolderID"] == nil && scopedManifest.references == [scope], "routing target remains local and source scope is explicit context")
        try expect(try client.resolveFileSelectionTarget(requestID: scopedChoose.requestID, existingFolderIDs: ["folder-A"]) == "folder-A", "result uses requested folder")
        try fails("deleted target never chooses first folder", expected: .requiresTargetReview) {
            _ = try client.resolveFileSelectionTarget(requestID: scopedChoose.requestID, existingFolderIDs: ["folder-B"])
        }
        try expect(try client.resolveFileSelectionTarget(requestID: scopedChoose.requestID, existingFolderIDs: ["folder-B"], userConfirmedFolderID: "folder-B") == "folder-B", "explicit re-target is persisted")
        let oldSessionURL = client.exchangeRoot.appendingPathComponent("Sessions/\(scopedChoose.requestID).json")
        var oldSessionObject = try JSONSerialization.jsonObject(with: Data(contentsOf: oldSessionURL)) as! [String: Any]
        for key in ["targetFolderID", "sourceScope", "selectionIntentVersion", "appliedResults", "resultStatuses"] { oldSessionObject.removeValue(forKey: key) }
        try write(JSONSerialization.data(withJSONObject: oldSessionObject), to: oldSessionURL)
        try expect(try client.loadSession(scopedChoose.requestID).targetFolderID == nil, "old sessions decode without inventing routing scope")
        try fails("legacy target requires review", expected: .requiresTargetReview) {
            _ = try client.resolveFileSelectionTarget(requestID: scopedChoose.requestID, existingFolderIDs: ["folder-A", "folder-B"])
        }

        let pdf = root.appendingPathComponent("input.pdf")
        try write(Data("%PDF-1.4\nfixture scanned pages\n".utf8), to: pdf)
        let ocr = try client.prepareOCR(userSelectedFiles: [.init(url: pdf, documentID: "doc-ocr")], languages: ["zh-Hans"], outputs: ["text"])
        let session = try client.loadSession(ocr.requestID)
        try expect(session.sources.count == 1 && fm.fileExists(atPath: pdf.path), "OCR retains original and persists source binding")
        let output = root.appendingPathComponent("output.txt")
        try write(Data("page one text\n".utf8), to: output)
        let source = session.sources[0]
        let partialMetadata: [String: GaoJSONValue] = [
            "sourceItemID": .string(source.itemID), "sourceSHA256": .string(source.sha256),
            "engine": .string("FixtureEngine"), "engineVersion": .string("fixture-1"), "languages": .array([.string("zh-Hans")]),
            "pages": .array([.object(["pageNumber": .number(1), "status": .string("completed"), "coordinateSpace": .string("normalized"), "text": .string("page one text"),
                                     "regions": .array([.object(["x": .number(0), "y": .number(0), "width": .number(0.5), "height": .number(0.2)])])]),
                              .object(["pageNumber": .number(2), "status": .string("failed")])])
        ]
        let partial = try result(root: root.appendingPathComponent("ProviderOutgoing"), request: ocr, action: .ocrFiles,
                                 status: "partial", outputFiles: [output], provenance: partialMetadata)
        let partialResult = try client.receiveResult(at: partial)
        try expect(partialResult.workflowState == "partial" && partialResult.ocrOutputs[0].pages.count == 2, "v1-ocr-partial page mapping")
        try expect(partialResult.ocrOutputs[0].sourceDocumentID == "doc-ocr", "OCR maps to original library document")
        let receivedAgain = try client.receiveResult(at: partial)
        try expect(receivedAgain.duplicate && !receivedAgain.businessApplied, "received-only duplicate remains available for approval/resume")
        let refreshed = try result(root: root.appendingPathComponent("ProviderOutgoing"), request: ocr, action: .ocrFiles,
                                   status: "partial", outputFiles: [output], provenance: partialMetadata)
        let refreshedManifestURL = refreshed.appendingPathComponent("manifest.json")
        var renewed = try JSONDecoder().decode(GaoActionManifest.self, from: Data(contentsOf: refreshedManifestURL))
        renewed.nonce = Data(repeating: 7, count: 32).base64EncodedString()
        renewed.expiresAt = "2026-10-12T12:01:59Z"
        try write(JSONEncoder().encode(renewed), to: refreshedManifestURL)
        let refreshedResult = try client.receiveResult(at: refreshed)
        let firstSemantic = try client.semanticResultFingerprint(partialResult, targetScope: "folder:fixture-target")
        let refreshedSemantic = try client.semanticResultFingerprint(refreshedResult, targetScope: "folder:fixture-target")
        try expect(partialResult.package.manifest.requestID != refreshedResult.package.manifest.requestID && firstSemantic == refreshedSemantic,
                   "new result UUID/TTL/nonce preserve business identity")
        try expect(try client.semanticResultFingerprint(refreshedResult, targetScope: "folder:other-target") != firstSemantic,
                   "semantic identity binds actual target scope")
        var changedProvenance = partialMetadata
        changedProvenance["engineVersion"] = .string("different-engine-revision")
        let changed = try result(root: root.appendingPathComponent("ProviderOutgoing"), request: ocr, action: .ocrFiles,
                                 status: "partial", outputFiles: [output], provenance: changedProvenance)
        let changedResult = try client.receiveResult(at: changed)
        try expect(try client.semanticResultFingerprint(changedResult, targetScope: "folder:fixture-target") != firstSemantic,
                   "semantic identity binds engine and page provenance")
        var changedPages = partialMetadata
        if case .array(var pages)? = changedPages["pages"] {
            pages[1] = .object(["pageNumber": .number(2), "status": .string("cancelled")])
            changedPages["pages"] = .array(pages)
        }
        let otherPages = try result(root: root.appendingPathComponent("ProviderOutgoing"), request: ocr, action: .ocrFiles,
                                    status: "partial", outputFiles: [output], provenance: changedPages)
        try expect(try client.semanticResultFingerprint(client.receiveResult(at: otherPages), targetScope: "folder:fixture-target") != firstSemantic,
                   "semantic identity cannot reuse a job with different page evidence")
        let pendingJob = UUID()
        try client.recordResultIntent(requestID: ocr.requestID, resultID: refreshedResult.package.manifest.requestID, jobID: pendingJob)
        let pendingSession = try client.loadSession(ocr.requestID)
        try expect(pendingSession.resultIntents?[refreshedResult.package.manifest.requestID]?.jobID == pendingJob.uuidString &&
                   pendingSession.appliedResults?[refreshedResult.package.manifest.requestID] == nil,
                   "write-ahead result intent is durable without an applied receipt")
        try fails("result intent cannot rebind", expected: .resultMismatch) {
            try client.recordResultIntent(requestID: ocr.requestID, resultID: refreshedResult.package.manifest.requestID, jobID: UUID())
        }
        try fails("applied receipt must use its bound job", expected: .resultMismatch) {
            _ = try client.markResultApplied(requestID: ocr.requestID, resultID: refreshedResult.package.manifest.requestID,
                                            importedDocumentIDs: ["fixture-doc"], receiptID: UUID().uuidString)
        }
        try expect(try !client.receiveResult(at: refreshed).businessApplied, "pending intent remains eligible for review and recovery")
        let partialManifestURL = partial.appendingPathComponent("manifest.json")
        var mutated = try JSONDecoder().decode(GaoActionManifest.self, from: Data(contentsOf: partialManifestURL))
        mutated.provenance?["engineVersion"] = .string("fixture-2")
        try write(JSONEncoder().encode(mutated), to: partialManifestURL)
        try fails("duplicate ID content conflict", expected: .resultMismatch) { _ = try client.receiveResult(at: partial) }
        let falseComplete = try result(root: root.appendingPathComponent("ProviderOutgoing"), request: ocr, action: .ocrFiles,
                                       status: "completed", outputFiles: [output], provenance: partialMetadata)
        try fails("failed page cannot be completed", expected: .invalidOCRCompletion) { _ = try client.receiveResult(at: falseComplete) }
        let minimal: [String: GaoJSONValue] = ["sourceItemID": .string(source.itemID), "sourceSHA256": .string(source.sha256)]
        let incomplete = try result(root: root.appendingPathComponent("ProviderOutgoing"), request: ocr, action: .ocrFiles,
                                    status: "partial", outputFiles: [output, output], provenance: minimal)
        let incompleteResult = try client.receiveResult(at: incomplete)
        try expect(incompleteResult.workflowState == "needsReview" && incompleteResult.ocrOutputs.count == 2,
                   "top-level single-source supports multiple outputs without inventing metadata")
        var wrongHash = minimal; wrongHash["sourceSHA256"] = .string(String(repeating: "0", count: 64))
        let conflict = try result(root: root.appendingPathComponent("ProviderOutgoing"), request: ocr, action: .ocrFiles,
                                 status: "partial", outputFiles: [output], provenance: wrongHash)
        try fails("OCR source hash conflict", expected: .invalidOCRMapping) { _ = try client.receiveResult(at: conflict) }
        let impersonated = try result(root: root.appendingPathComponent("ProviderOutgoing"), request: ocr, action: .ocrFiles,
                                     status: "partial", outputFiles: [output], provenance: minimal, sourceID: "com.example.other")
        try fails("source claim mismatch", expected: .resultMismatch) { _ = try client.receiveResult(at: impersonated) }
        try productionOCRFixtures(root: root, client: client, originalPDF: pdf, firstOutput: output)
        try write(Data("%PDF-1.4 changed\n".utf8), to: pdf)
        try fails("changed original blocks result import", expected: .sourceChanged) { _ = try client.receiveResult(at: incomplete) }

        let original = root.appendingPathComponent("original.docx")
        let edited = root.appendingPathComponent("edited.docx")
        try write(Data("original fixture\n".utf8), to: original)
        try write(Data("edited fixture\n".utf8), to: edited)
        let version = fixedNow
        let edit = try client.prepareExternalEdit(documentID: "managed-1", originalURL: original, originalVersion: version)
        let opened = try result(root: root.appendingPathComponent("ProviderOutgoing"), request: edit, action: .openDocument,
                                status: "completed", provenance: ["workflowState": .string("opened")])
        try expect(try client.receiveResult(at: opened).workflowState == "opened", "open receipt is not a saved revision")
        let editSession = try client.loadSession(edit.requestID)
        for state in ["pending", "partial", "failed", "cancelled"] {
            let receipt = try result(root: root.appendingPathComponent("ProviderOutgoing"), request: edit, action: .openDocument,
                                     status: state, provenance: ["workflowState": .string(state), "saved": .bool(false),
                                                                "openedItemIDs": .array(state == "partial" ? [.string(editSession.sources[0].itemID)] : [])])
            let received = try client.receiveResult(at: receipt)
            try expect(received.workflowState == state && !received.businessApplied, "real editor pending/partial/failure remains an unsaved receipt")
        }
        let falseSave = try result(root: root.appendingPathComponent("ProviderOutgoing"), request: edit, action: .openDocument,
                                   status: "completed", provenance: ["workflowState": .string("opened"), "saved": .bool(true)])
        try fails("open receipt cannot claim edit saved", expected: .invalidEditResult) { _ = try client.receiveResult(at: falseSave) }
        let savedClaim = try result(root: root.appendingPathComponent("ProviderOutgoing"), request: edit, action: .openDocument,
                                    status: "completed", outputFiles: [edited], provenance: ["workflowState": .string("saved")])
        try fails("editing return cannot auto-overwrite", expected: .invalidEditResult) { _ = try client.receiveResult(at: savedClaim) }
        let prepared = try client.prepareEditedCopyImport(requestID: edit.requestID, currentDocumentID: "managed-1", currentOriginalURL: original,
                                                         currentVersion: version, userSelectedEditedCopy: edited, mode: .newVersion)
        try expect(try Data(contentsOf: original) == Data("original fixture\n".utf8), "prepare edited import never replaces original")
        try expect(prepared.mode == .newVersion && prepared.originalDocumentID == "managed-1", "explicit new version preserves relation")
        try client.markEditedCopyImported(prepared)
        try fails("re-import same edited copy", expected: .alreadyImported) {
            _ = try client.prepareEditedCopyImport(requestID: edit.requestID, currentDocumentID: "managed-1", currentOriginalURL: original,
                                                   currentVersion: version, userSelectedEditedCopy: edited, mode: .newAttachment)
        }
        try fails("version conflict", expected: .sourceChanged) {
            _ = try client.prepareEditedCopyImport(requestID: edit.requestID, currentDocumentID: "managed-1", currentOriginalURL: original,
                                                   currentVersion: version.addingTimeInterval(1), userSelectedEditedCopy: edited, mode: .newVersion)
        }
        print("Research exchange client contract fixtures passed: \(checks) checks; no installed-provider or GUI end-to-end claim")
    }

    // Shapes below are copied from the public fields emitted by the read-only
    // GaoJieTu Sources/UI/ExchangeController.swift producer, not a new V1 schema.
    // No OCR engine, installed app or GUI is started by these codec fixtures.
    static func productionOCRFixtures(root: URL, client: ResearchExchangeClient,
                                       originalPDF: URL, firstOutput: URL) throws {
        let image = root.appendingPathComponent("second-input.png")
        let json = root.appendingPathComponent("ocr.json")
        let emptyText = root.appendingPathComponent("failed-source.txt")
        try write(Data("synthetic image bytes; this test does not recognize images".utf8), to: image)
        try write(Data("{\"schemaVersion\":1,\"fixture\":true}".utf8), to: json)
        try write(Data(), to: emptyText)
        let request = try client.prepareOCR(userSelectedFiles: [.init(url: originalPDF, documentID: "pdf-original"),
                                                                .init(url: image, documentID: "image-original")])
        let session = try client.loadSession(request.requestID)
        let first = session.sources[0], second = session.sources[1]
        func source(_ binding: ResearchExchangeSourceBinding, providerID: String, outputIDs: [String], status: String) -> GaoJSONValue {
            .object(["sourceID": .string(providerID), "sourceItemID": .string(binding.itemID), "sourceSHA256": .string(binding.sha256),
                     "outputItemIDs": .array(outputIDs.map(GaoJSONValue.string)),
                     "pages": .array([.object(["pageNumber": .number(1), "status": .string(status), "elapsedSeconds": .number(0.1),
                                                "lineCount": .number(status == "completed" ? 3 : 0),
                                                "failureReason": status == "completed" ? .null : .string("recognitionFailed")])])])
        }
        func mapping(_ binding: ResearchExchangeSourceBinding, providerID: String, outputID: String, format: String,
                     key: String = "resultItemID") -> GaoJSONValue {
            .object(["sourceID": .string(providerID), "sourceItemID": .string(binding.itemID), "sourceSHA256": .string(binding.sha256),
                     key: .string(outputID), "format": .string(format)])
        }
        let firstProviderID = UUID().uuidString, secondProviderID = UUID().uuidString
        let provenance: [String: GaoJSONValue] = [
            "engine": .string("Apple Vision VNRecognizeTextRequest"), "engineRevision": .number(3), "networkUsed": .bool(false),
            "sources": .array([source(first, providerID: firstProviderID, outputIDs: ["output-0", "output-1"], status: "completed"),
                                source(second, providerID: secondProviderID, outputIDs: ["output-2"], status: "failed")]),
            "outputs": .array([mapping(first, providerID: firstProviderID, outputID: "output-0", format: "text"),
                                mapping(first, providerID: firstProviderID, outputID: "output-1", format: "json"),
                                mapping(second, providerID: secondProviderID, outputID: "output-2", format: "text")]),
            "exportFailures": .array([])
        ]
        let outgoing = root.appendingPathComponent("ProviderProductionShape")
        let partial = try result(root: outgoing, request: request, action: .ocrFiles, status: "partial",
                                 outputFiles: [firstOutput, json, emptyText], provenance: provenance,
                                 outputUTIs: ["public.utf8-plain-text", "public.json", "public.utf8-plain-text"])
        let checked = try client.receiveResult(at: partial)
        try expect(checked.ocrOutputs.count == 3 && checked.package.manifest.status == "partial", "production resultItemID supports multiple inputs and formats")
        try expect(checked.ocrOutputs[0].sourceDocumentID == "pdf-original" && checked.ocrOutputs[1].sourceDocumentID == "pdf-original"
                   && checked.ocrOutputs[2].sourceDocumentID == "image-original", "each production output binds its own source")
        for output in checked.ocrOutputs {
            let actual = try GaoActionFileAccess.fingerprint(at: output.localCopy)
            try expect(output.localCopy.deletingLastPathComponent() == checked.package.stagingDirectory
                       && actual.sha256 == output.sha256 && actual.byteCount == output.byteCount,
                       "business importer receives a verified staged output descriptor")
            try expect(output.engine == "Apple Vision VNRecognizeTextRequest" && output.engineRevision == 3 && output.engineVersion == "revision 3",
                       "top-level engine revision is preserved")
            try expect(output.pages.count == 1 && output.pages[0].confidence == nil && output.languages.isEmpty && !output.metadataComplete,
                       "absent confidence and language remain absent")
        }
        try expect(!checked.businessApplied && checked.workflowState == "needsReview", "partial receipt waits for explicit business approval")
        let reorderedURL = try result(root: outgoing, request: request, action: .ocrFiles, status: "partial",
                                      outputFiles: [firstOutput, json, emptyText], provenance: provenance,
                                      outputUTIs: ["public.utf8-plain-text", "public.json", "public.utf8-plain-text"])
        let reorderManifestURL = reorderedURL.appendingPathComponent("manifest.json")
        var reordered = try JSONDecoder().decode(GaoActionManifest.self, from: Data(contentsOf: reorderManifestURL))
        reordered.items.reverse()
        for key in ["sources", "outputs"] {
            if case .array(let entries)? = reordered.provenance?[key] { reordered.provenance?[key] = .array(entries.reversed()) }
        }
        try write(JSONEncoder().encode(reordered), to: reorderManifestURL)
        let orderIndependent = try client.receiveResult(at: reorderedURL)
        try expect(try client.semanticResultFingerprint(checked, targetScope: "same-target") == client.semanticResultFingerprint(orderIndependent, targetScope: "same-target"),
                   "irrelevant item/source/output ordering does not duplicate business work")
        let repeated = try client.receiveResult(at: partial)
        try expect(repeated.duplicate && !repeated.businessApplied, "partial retry is still recoverable before import")
        _ = try client.markResultApplied(requestID: request.requestID, resultID: checked.package.manifest.requestID,
                                        importedDocumentIDs: ["derivative-0", "derivative-1"], receiptID: "real-journal-fixture")
        try expect(try client.receiveResult(at: partial).businessApplied, "partial business commit is explicitly marked")
        let falseComplete = try result(root: outgoing, request: request, action: .ocrFiles, status: "completed",
                                       outputFiles: [firstOutput, json, emptyText], provenance: provenance,
                                       outputUTIs: ["public.utf8-plain-text", "public.json", "public.utf8-plain-text"])
        try fails("production failed page cannot be complete", expected: .invalidOCRCompletion) { _ = try client.receiveResult(at: falseComplete) }
        var hiddenFailure = provenance
        hiddenFailure["outputs"] = .array([mapping(first, providerID: firstProviderID, outputID: "output-0", format: "text")])
        hiddenFailure["sources"] = .array([source(first, providerID: firstProviderID, outputIDs: ["output-0"], status: "completed"),
                                            source(second, providerID: secondProviderID, outputIDs: [], status: "failed")])
        let noFailedOutput = try result(root: outgoing, request: request, action: .ocrFiles, status: "completed", outputFiles: [firstOutput], provenance: hiddenFailure)
        try fails("failed input without output cannot disappear", expected: .invalidOCRCompletion) { _ = try client.receiveResult(at: noFailedOutput) }
        for state in ["failed", "pending"] {
            let package = try result(root: outgoing, request: request, action: .ocrFiles, status: state,
                                     outputFiles: [firstOutput, json, emptyText], provenance: provenance,
                                     outputUTIs: ["public.utf8-plain-text", "public.json", "public.utf8-plain-text"])
            let received = try client.receiveResult(at: package)
            try expect(received.workflowState == state && !received.businessApplied, "failed/pending state is not promoted by metadata review")
            try fails("failed/pending cannot be business complete", expected: .invalidSession) {
                _ = try client.markResultApplied(requestID: request.requestID, resultID: received.package.manifest.requestID,
                                                importedDocumentIDs: ["not-imported"], receiptID: "invalid-receipt")
            }
        }
        let single = try client.prepareOCR(userSelectedFiles: [.init(url: originalPDF, documentID: "single-original")])
        let singleSource = try client.loadSession(single.requestID).sources[0]
        for state in ["lowConfidence", "pending"] {
            let metadata: [String: GaoJSONValue] = ["sourceItemID": .string(singleSource.itemID), "sourceSHA256": .string(singleSource.sha256),
                                                   "pages": .array([.object(["pageNumber": .number(1), "status": .string(state)])])]
            let package = try result(root: outgoing, request: single, action: .ocrFiles, status: "completed", outputFiles: [firstOutput], provenance: metadata)
            try fails("unfinished page cannot be complete", expected: .invalidOCRCompletion) { _ = try client.receiveResult(at: package) }
        }
        let legacyProvenance: [String: GaoJSONValue] = [
            "outputs": .array([mapping(singleSource, providerID: firstProviderID, outputID: "output-0", format: "text", key: "itemID")]),
            "engine": .string("LegacyFixtureEngine"), "engineVersion": .string("1"), "languages": .array([.string("en-US")]),
            "pages": .array([.object(["pageNumber": .number(1), "status": .string("completed")])])
        ]
        let legacy = try result(root: outgoing, request: single, action: .ocrFiles, status: "completed", outputFiles: [firstOutput], provenance: legacyProvenance)
        try expect(try client.receiveResult(at: legacy).ocrOutputs[0].metadataComplete, "legacy itemID output mapping remains supported")
    }
}
