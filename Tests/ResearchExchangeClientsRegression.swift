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
                       provenance: [String: GaoJSONValue], sourceID: String? = nil) throws -> URL {
        let items = outputFiles.enumerated().map { index, url in
            GaoActionItem(id: "output-\(index)", relativePath: "payload/output-\(index).\(url.pathExtension)",
                          uti: "public.plain-text", byteCount: 0, sha256: String(repeating: "0", count: 64))
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
        try expect(try client.receiveResult(at: partial).duplicate, "v1-duplicate-request does not repeat import")
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
}
