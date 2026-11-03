import Foundation
import CryptoKit

/// Exercises production routing, send gates and historical-session result
/// validation with private synthetic data. Never opens a provider or an App.
@main
struct ResearchProviderConsolidationRegression {
    static let researchID = "com.academic-achievement.manager"
    static let filesID = "com.gaoseries.GaoWenJian"
    static let oldFilesID = "com.gaoseries.GaoZhengLi"
    static let operationID = "com.gaoseries.GaoCaoZuo"
    static let oldScreenshotID = "com.gaoseries.GaoJieTu"
    static let fm = FileManager.default
    static var checks = 0

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NSError(domain: "ProviderConsolidation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }

    static func rejects<E: Error & Equatable>(_ expected: E, _ message: String, _ work: () throws -> Void) throws {
        do { try work() }
        catch let error as E { return try expect(error == expected, message + ": wrong rejection") }
        throw NSError(domain: "ProviderConsolidation", code: 2, userInfo: [NSLocalizedDescriptionKey: message + ": accepted"])
    }

    static func write(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func fixtureProvider(_ root: URL, id: String, includesAction: Bool = true,
                                action: ResearchExternalAction = .chooseFiles) throws -> URL {
        // The explicit root must already be .noindex before creating a bundle.
        let app = root.appendingPathComponent(UUID().uuidString + ".app", isDirectory: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": "1.10",
                                   "CFBundlePackageType": "APPL", "CFBundleExecutable": "FixtureOnly"]
        try write(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), to: app.appendingPathComponent("Contents/Info.plist"))
        let properties: [String: GaoJSONValue] = action == .ocrFiles
            ? ["languages": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
               "outputs": .object(["type": .string("array"), "maxItems": .number(4), "items": .object(["type": .string("string")])])]
            : ["multiple": .object(["type": .string("boolean")]),
               "allowedUTIs": .object(["type": .string("array"), "maxItems": .number(64), "items": .object(["type": .string("string")])])]
        let schema: [String: GaoJSONValue] = [
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object(properties)
        ]
        let actions: [GaoJSONValue] = includesAction
            ? [.object(["action": .string(action.rawValue), "parametersSchema": .object(schema),
                        "selectionModes": .array([.string("references"), .string("copies")])])]
            : [.object(["action": .string("documents.open"), "parametersSchema": .object([
                "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])])]
        let capability: GaoJSONValue = .object(["schemaVersion": .number(1), "bundleID": .string(id),
                                               "appVersion": .string("1.10"), "actions": .array(actions)])
        try write(JSONEncoder().encode(capability), to: app.appendingPathComponent("Contents/Resources/GaoCapabilities.json"))
        return app
    }

    static func manifest(action: String, target: String, parameters: [String: GaoJSONValue] = [:],
                         references: [GaoActionReference] = [], now: Date = Date()) -> GaoActionManifest {
        // Capture once: two default Date() calls plus a cold formatter can
        // accidentally create a test envelope whose lifetime exceeds120s.
        GaoActionManifest(sourceBundleID: researchID, targetBundleID: target, action: action,
                          createdAt: GaoActionISO8601.string(now),
                          expiresAt: GaoActionISO8601.string(now.addingTimeInterval(120)),
                          nonce: Data(repeating: 7, count: 32).base64EncodedString(),
                          references: references, parameters: parameters)
    }

    static func routing(_ root: URL) throws {
        // All direct manifest validators in this phase share one exact clock.
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let file = root.appendingPathComponent("selected.txt")
        try write(Data("synthetic selected research attachment\n".utf8), to: file)
        let reference = try GaoActionReference.capture(at: file, kind: "file")
        let routes: [(String, String, String, [String: GaoJSONValue], [GaoActionReference])] = [
            ("files.choose", filesID, oldFilesID, ["multiple": .bool(true)], []),
            ("files.search", filesID, oldFilesID, ["query": .string("synthetic")], []),
            ("files.reveal", filesID, oldFilesID, [:], [reference]),
            ("associations.manage", filesID, oldFilesID, ["uti": .string("public.plain-text")], []),
            ("windows.overview", "com.gaoseries.GaoCaoZuo", "com.gaoseries.GaoZhuoMian", [:], []),
            ("desktop.openSettings", "com.gaoseries.GaoCaoZuo", "com.gaoseries.GaoZhuoMian", [:], []),
            ("downloads.prepare", "cn.mendao.launcher", "com.gaoseries.GaoXiaZai", ["urls": .array([.string("https://example.com/public.txt")]), "mediaType": .string("file")], [])
        ]
        for (action, current, retired, parameters, references) in routes {
            let m = manifest(action: action, target: current, parameters: parameters, references: references, now: now)
            try GaoActionPackageValidator(expectedTargetBundleID: current, now: now).validateManifest(m)
            try expect(true, action + " accepts its current provider")
            var old = m; old.targetBundleID = retired
            try rejects(GaoActionError.wrongTarget, action + " rejects the retired request target") {
                try GaoActionPackageValidator(expectedTargetBundleID: retired, now: now).validateManifest(old)
            }
            var confused = m; confused.targetBundleID = "com.example.WrongReceiver"
            try rejects(GaoActionError.wrongTarget, action + " rejects an unrelated receiver") {
                try GaoActionPackageValidator(expectedTargetBundleID: confused.targetBundleID, now: now).validateManifest(confused)
            }
        }
        let repositoryLabelAsTarget = manifest(action: "downloads.prepare", target: "com.gaoseries.GaoMenHu",
                                               parameters: ["urls": .array([.string("https://example.com/public.txt")])], now: now)
        try rejects(GaoActionError.wrongTarget, "repository label cannot replace actual Portal bundle identity") {
            try GaoActionPackageValidator(expectedTargetBundleID: repositoryLabelAsTarget.targetBundleID, now: now).validateManifest(repositoryLabelAsTarget)
        }
        let portalRequest = manifest(action: "portal.focusSearch", target: "cn.mendao.launcher", parameters: ["query": .string("synthetic")], now: now)
        try GaoActionPackageValidator(expectedTargetBundleID: portalRequest.targetBundleID, now: now).validateManifest(portalRequest)
        try expect(true, "existing portal actions retain their original host identity")
        var unsafe = manifest(action: "downloads.prepare", target: "cn.mendao.launcher",
                              parameters: ["urls": .array([.string("file:///private/sensitive.txt")])], now: now)
        try rejects(GaoActionError.invalidParameters, "consolidation keeps URL safety restrictions") {
            try GaoActionPackageValidator(expectedTargetBundleID: unsafe.targetBundleID, now: now).validateManifest(unsafe)
        }
        unsafe = manifest(action: "files.choose", target: filesID, parameters: ["command": .string("do not execute")], now: now)
        try rejects(GaoActionError.invalidParameters, "consolidation keeps the parameter allowlist") {
            try GaoActionPackageValidator(expectedTargetBundleID: filesID, now: now).validateManifest(unsafe)
        }
        try expect(ResearchExternalAction.openDocument.providerBundleID == filesID, "document editing remains with GaoWenJian")
        try expect(ResearchExternalAction.ocrFiles.providerBundleID == operationID, "new OCR provider is GaoCaoZuo")
        let timed = manifest(action: "files.choose", target: filesID, now: now)
        try GaoActionPackageValidator(expectedTargetBundleID: filesID, now: now.addingTimeInterval(119)).validateManifest(timed)
        try expect(true, "same bound request is valid before its120-second expiry")
        try rejects(GaoActionError.expired, "replaying the identical request at expiry remains forbidden") {
            try GaoActionPackageValidator(expectedTargetBundleID: filesID, now: now.addingTimeInterval(120)).validateManifest(timed)
        }
        var tooLong = timed
        tooLong.expiresAt = GaoActionISO8601.string(now.addingTimeInterval(121))
        try rejects(GaoActionError.expired, "a121-second envelope is not accepted by clock alignment") {
            try GaoActionPackageValidator(expectedTargetBundleID: filesID, now: now).validateManifest(tooLong)
        }
        let stale = manifest(action: "files.choose", target: filesID, now: now.addingTimeInterval(-121))
        try rejects(GaoActionError.expired, "already expired envelope remains rejected") {
            try GaoActionPackageValidator(expectedTargetBundleID: filesID, now: now).validateManifest(stale)
        }
        let bytes = try Data(contentsOf: file)
        let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let image = GaoActionItem(id: "image-input", relativePath: "payload/input.png", uti: "public.png", byteCount: Int64(bytes.count), sha256: checksum)
        let text = GaoActionItem(id: "text-input", relativePath: "payload/input.txt", uti: "public.plain-text", byteCount: Int64(bytes.count), sha256: checksum)
        let screenshotRoutes: [(String, [String: GaoJSONValue], [GaoActionItem])] = [
            ("capture.region", ["delaySeconds": .number(1)], []),
            ("capture.window", [:], []),
            ("capture.display", [:], []),
            ("ocr.files", ["languages": .array([.string("en-US")]), "outputs": .array([.string("text")])], [image]),
            ("images.annotate", [:], [image]),
            ("images.pin", [:], [image]),
            ("text.translate", ["targetLanguage": .string("en-US")], [text])
        ]
        for (action, parameters, items) in screenshotRoutes {
            var current = manifest(action: action, target: operationID, parameters: parameters, now: now)
            current.items = items
            try GaoActionPackageValidator(expectedTargetBundleID: operationID, now: now).validateManifest(current)
            try expect(true, action + " accepts only new operation owner")
            var old = current; old.targetBundleID = oldScreenshotID
            try rejects(GaoActionError.wrongTarget, action + " rejects retired screenshot request owner") {
                try GaoActionPackageValidator(expectedTargetBundleID: oldScreenshotID, now: now).validateManifest(old)
            }
            var wrong = current; wrong.targetBundleID = filesID
            try rejects(GaoActionError.wrongTarget, action + " rejects unrelated new receiver") {
                try GaoActionPackageValidator(expectedTargetBundleID: filesID, now: now).validateManifest(wrong)
            }
        }
    }

    static func discoveryAndNewRequests(_ root: URL) throws {
        let provider = try fixtureProvider(root, id: filesID)
        let retired = try fixtureProvider(root, id: oldFilesID)
        let documentOnly = try fixtureProvider(root, id: filesID, includesAction: false)
        var requestedIDs: [String] = []
        let client = ResearchExchangeClient(exchangeRoot: root.appendingPathComponent("NewExchange"), researchBundleID: researchID,
                                            providerLookup: { id in requestedIDs.append(id); return id == filesID ? provider : retired })
        let prepared = try client.prepareFileSelection(allowedUTIs: ["public.plain-text"], targetFolderID: "explicit-folder")
        let received = try GaoActionPackageValidator(expectedTargetBundleID: filesID).stagePackage(at: prepared.packageURL, stagingRoot: root.appendingPathComponent("ProviderStaging"))
        try expect(received.manifest.targetBundleID == filesID && received.manifest.action == "files.choose", "new wire request targets only GaoWenJian")
        let session = try client.loadSession(prepared.requestID)
        try expect(session.providerBundleID == filesID && session.state == "prepared" && session.resultIDs.isEmpty, "new session binding is current but not completed")
        try expect(session.targetFolderID == "explicit-folder", "local target preserved")
        try expect(received.manifest.parameters["targetFolderID"] == nil, "target remains local")
        try expect(client.availability(for: .chooseFiles, parameters: prepared.parameters).isAvailable, "new provider strict array capability compatible")
        try expect(requestedIDs == [filesID], "discovery never probes the retired provider")
        try client.validatePreparedRequestForSending(prepared)
        let retiredOnly = ResearchExchangeClient(exchangeRoot: root.appendingPathComponent("Unused"), researchBundleID: researchID,
                                                 providerLookup: { id in id == oldFilesID ? retired : nil })
        try expect(!retiredOnly.availability(for: .chooseFiles).isAvailable, "old-only installation is unavailable without fallback")
        let wrongBundle = ResearchExchangeClient(exchangeRoot: root.appendingPathComponent("Unused"), researchBundleID: researchID, providerLookup: { _ in retired })
        try expect(!wrongBundle.availability(for: .chooseFiles).isAvailable, "new lookup cannot accept an old bundle disguised by URL")
        let oldEditorVersion = ResearchExchangeClient(exchangeRoot: root.appendingPathComponent("Unused"), researchBundleID: researchID, providerLookup: { _ in documentOnly })
        try expect(!oldEditorVersion.availability(for: .chooseFiles).isAvailable, "documents-only GaoWenJian cannot pretend to choose files")
        let malformed = try fixtureProvider(root, id: filesID)
        try write(Data("not JSON".utf8), to: malformed.appendingPathComponent("Contents/Resources/GaoCapabilities.json"))
        let corrupt = ResearchExchangeClient(exchangeRoot: root.appendingPathComponent("Unused"), researchBundleID: researchID, providerLookup: { _ in malformed })
        try expect(!corrupt.availability(for: .chooseFiles).isAvailable, "damaged capability fails closed")
    }

    static func ocrDiscoveryAndHistoricalSession(_ root: URL) throws {
        let currentProvider = try fixtureProvider(root, id: operationID, action: .ocrFiles)
        let oldProvider = try fixtureProvider(root, id: oldScreenshotID, action: .ocrFiles)
        let lacksOCR = try fixtureProvider(root, id: operationID, includesAction: false, action: .ocrFiles)
        var requestedIDs: [String] = []
        let client = ResearchExchangeClient(exchangeRoot: root.appendingPathComponent("OCRExchange"), researchBundleID: researchID,
                                            providerLookup: { id in requestedIDs.append(id); return id == operationID ? currentProvider : nil })
        let pdf = root.appendingPathComponent("synthetic-ocr.pdf")
        try write(Data("synthetic fingerprint binding; no PDF rendering or OCR engine\n".utf8), to: pdf)
        let prepared = try client.prepareOCR(userSelectedFiles: [.init(url: pdf, documentID: "synthetic-ocr-document")], languages: ["en-US"], outputs: ["text"])
        let request = try GaoActionPackageValidator(expectedTargetBundleID: operationID)
            .stagePackage(at: prepared.packageURL, stagingRoot: root.appendingPathComponent("OCRProviderStaging"))
        try expect(request.manifest.targetBundleID == operationID && request.manifest.action == "ocr.files", "new OCR wire request targets operation")
        try expect(client.availability(for: .ocrFiles, parameters: prepared.parameters).isAvailable, "OCR capability uses exact current owner and parameter schema")
        try expect(requestedIDs == [operationID], "OCR discovery never probes retired screenshot app")
        try client.validatePreparedRequestForSending(prepared)
        let session = try client.loadSession(prepared.requestID)
        try expect(session.providerBundleID == operationID && session.state == "prepared" && session.sources.count == 1, "new OCR session retains source binding without completion")
        let retiredOnly = ResearchExchangeClient(exchangeRoot: root.appendingPathComponent("UnusedOCR"), researchBundleID: researchID,
                                                 providerLookup: { id in id == oldScreenshotID ? oldProvider : nil })
        try expect(!retiredOnly.availability(for: .ocrFiles, parameters: prepared.parameters).isAvailable, "old screenshot installation is not an OCR fallback")
        let wrongBundle = ResearchExchangeClient(exchangeRoot: root.appendingPathComponent("UnusedOCR"), researchBundleID: researchID, providerLookup: { _ in oldProvider })
        try expect(!wrongBundle.availability(for: .ocrFiles, parameters: prepared.parameters).isAvailable, "OCR discovery rejects a retired bundle at supplied URL")
        let missingCapability = ResearchExchangeClient(exchangeRoot: root.appendingPathComponent("UnusedOCR"), researchBundleID: researchID, providerLookup: { _ in lacksOCR })
        try expect(!missingCapability.availability(for: .ocrFiles, parameters: prepared.parameters).isAvailable, "operation without OCR implementation capability remains unavailable")
        try expect(!client.availability(for: .ocrFiles, parameters: ["languages": .string("en-US")]).isAvailable, "OCR parameter types still fail closed")

        // Recreate a retained pre-consolidation session, preserving its source
        // binding and nonce. No production request writer targets the old App.
        var oldRequest = request.manifest
        oldRequest.requestID = UUID().uuidString; oldRequest.targetBundleID = oldScreenshotID
        let oldPackage = client.exchangeRoot.appendingPathComponent("Outgoing/" + oldRequest.requestID + ".gaoaction")
        try write(JSONEncoder().encode(oldRequest), to: oldPackage.appendingPathComponent("manifest.json"))
        var oldSession = session
        oldSession.requestID = oldRequest.requestID; oldSession.providerBundleID = oldScreenshotID
        oldSession.packageURL = oldPackage.absoluteString; oldSession.state = "needsReview"
        let oldSessionURL = client.exchangeRoot.appendingPathComponent("Sessions/" + oldRequest.requestID + ".json")
        let oldBytes = try JSONEncoder().encode(oldSession)
        try write(oldBytes, to: oldSessionURL)
        let oldPrepared = ResearchPreparedExchange(packageURL: oldPackage, requestID: oldRequest.requestID, action: .ocrFiles, parameters: oldRequest.parameters)
        try rejects(ResearchExchangeClientError.providerChanged, "old OCR request must not be sent to new operation provider") {
            try client.validatePreparedRequestForSending(oldPrepared)
        }
        try expect(try Data(contentsOf: oldSessionURL) == oldBytes, "old OCR needsReview state and session bytes survive rejected send")
        var reply = GaoActionManifest(kind: "result", sourceBundleID: operationID, targetBundleID: researchID,
                                      action: "ocr.files", inReplyTo: oldRequest.requestID, status: "pending",
                                      provenance: ["workflowState": .string("awaitingUser")])
        let wrongSource = try GaoActionPackageWriter().write(manifest: reply, files: [:], outgoingRoot: root.appendingPathComponent("NewOCRProviderOutgoing"))
        try rejects(ResearchExchangeClientError.resultMismatch, "operation cannot claim retired screenshot OCR session") {
            _ = try client.receiveResult(at: wrongSource)
        }
        try expect(try Data(contentsOf: oldSessionURL) == oldBytes, "wrong OCR source does not rewrite retained history")
        reply.sourceBundleID = oldScreenshotID; reply.requestID = UUID().uuidString
        let actualOldReply = try GaoActionPackageWriter().write(manifest: reply, files: [:], outgoingRoot: root.appendingPathComponent("RetainedScreenshotOutgoing"))
        let pending = try client.receiveResult(at: actualOldReply)
        try expect(pending.session.providerBundleID == oldScreenshotID && pending.workflowState == "pending" && pending.ocrOutputs.isEmpty,
                   "valid old OCR reply matches original provider and remains pending without output")
        try expect(!pending.businessApplied && !pending.duplicate, "legacy OCR pending receipt imports nothing")
        let repeated = try client.receiveResult(at: actualOldReply)
        try expect(repeated.duplicate && !repeated.businessApplied && repeated.ocrOutputs.isEmpty, "legacy OCR receipt replay does not create business output")
        let output = root.appendingPathComponent("retained-ocr-output.txt")
        try write(Data("retained synthetic OCR text\n".utf8), to: output)
        let source = session.sources[0]
        let evidence: [String: GaoJSONValue] = [
            "sourceItemID": .string(source.itemID), "sourceSHA256": .string(source.sha256),
            "engine": .string("isolated-contract-fixture"), "engineVersion": .string("1"),
            "languages": .array([.string("en-US")]),
            "pages": .array([.object(["pageNumber": .number(1), "status": .string("completed"),
                                      "text": .string("retained synthetic OCR text"), "confidence": .number(0.99)])])
        ]
        let partialTemplate = GaoActionManifest(kind: "result", sourceBundleID: oldScreenshotID, targetBundleID: researchID,
                                                action: "ocr.files", items: [.init(id: "retained-output", relativePath: "payload/result.txt",
                                                                                  uti: "public.plain-text", byteCount: 0, sha256: String(repeating: "0", count: 64))],
                                                inReplyTo: oldRequest.requestID, status: "partial", provenance: evidence)
        let oldPartial = try GaoActionPackageWriter().write(manifest: partialTemplate, files: ["retained-output": output],
                                                            outgoingRoot: root.appendingPathComponent("RetainedScreenshotOutgoing"))
        let partial = try client.receiveResult(at: oldPartial)
        try expect(partial.workflowState == "partial" && partial.ocrOutputs.count == 1 && !partial.businessApplied,
                   "real old-provider output is accepted for review without pretending business import")
        try expect(partial.ocrOutputs[0].sourceDocumentID == "synthetic-ocr-document"
                   && partial.ocrOutputs[0].sourceSHA256 == source.sha256 && partial.ocrOutputs[0].metadataComplete,
                   "old OCR output keeps exact document hash and original page evidence")
        try expect(try Data(contentsOf: partial.ocrOutputs[0].localCopy) == Data(contentsOf: output), "old OCR staged output bytes verified")
        let partialRepeated = try client.receiveResult(at: oldPartial)
        try expect(partialRepeated.duplicate && !partialRepeated.businessApplied && partialRepeated.ocrOutputs.count == 1,
                   "repeated legacy OCR output remains receipt duplicate without applying business twice")
        let originalFingerprint = try GaoActionFileAccess.fingerprint(at: pdf)
        try expect(session.sources.first?.sha256 == originalFingerprint.sha256, "legacy result handling preserves original input bytes")
    }

    static func historicalSessions(_ root: URL) throws {
        let exchange = root.appendingPathComponent("HistoricalExchange")
        var lookupCount = 0
        let client = ResearchExchangeClient(exchangeRoot: exchange, researchBundleID: researchID, providerLookup: { _ in lookupCount += 1; return nil })
        let oldRequest = manifest(action: "files.choose", target: oldFilesID, parameters: ["multiple": .bool(true)])
        let package = exchange.appendingPathComponent("Outgoing/" + oldRequest.requestID + ".gaoaction", isDirectory: true)
        try write(JSONEncoder().encode(oldRequest), to: package.appendingPathComponent("manifest.json"))
        let oldSession = ResearchExchangeSession(requestID: oldRequest.requestID, providerBundleID: oldFilesID, action: .chooseFiles,
                                                 requestNonce: oldRequest.nonce, packageURL: package.absoluteString, createdAt: Date(),
                                                 sources: [], state: "opened", resultIDs: [], importedEditedSHA256: nil,
                                                 targetFolderID: "historical-folder", selectionIntentVersion: 1)
        let sessionURL = exchange.appendingPathComponent("Sessions/" + oldRequest.requestID + ".json")
        let oldBytes = try JSONEncoder().encode(oldSession)
        try write(oldBytes, to: sessionURL)
        let prepared = ResearchPreparedExchange(packageURL: package, requestID: oldRequest.requestID, action: .chooseFiles, parameters: oldRequest.parameters)
        try expect(try client.recentSessions().first?.providerBundleID == oldFilesID, "history retains its original provider")
        try expect(try client.loadSession(oldRequest.requestID).state == "opened", "listing does not invent a terminal status")
        try rejects(ResearchExchangeClientError.providerChanged, "old request cannot be rerouted or replayed") {
            try client.validatePreparedRequestForSending(prepared)
        }
        try expect(lookupCount == 0, "legacy send stops before provider discovery or launch")
        try expect(try Data(contentsOf: sessionURL) == oldBytes, "read and rejected send leave historical session byte-identical")
        var reply = GaoActionManifest(kind: "result", sourceBundleID: filesID, targetBundleID: researchID,
                                      action: "files.choose", inReplyTo: oldRequest.requestID, status: "pending",
                                      provenance: ["workflowState": .string("awaitingUser")])
        let impostor = try GaoActionPackageWriter().write(manifest: reply, files: [:], outgoingRoot: root.appendingPathComponent("ImpostorOutgoing"))
        try rejects(ResearchExchangeClientError.resultMismatch, "current provider cannot claim old provider result") {
            _ = try client.receiveResult(at: impostor)
        }
        try expect(try Data(contentsOf: sessionURL) == oldBytes, "wrong source result does not rewrite old session")
        reply.sourceBundleID = oldFilesID; reply.requestID = UUID().uuidString
        let originalReply = try GaoActionPackageWriter().write(manifest: reply, files: [:], outgoingRoot: root.appendingPathComponent("HistoricalProviderOutgoing"))
        let received = try client.receiveResult(at: originalReply)
        try expect(received.session.providerBundleID == oldFilesID && received.workflowState == "pending", "valid old reply retains old source and pending state")
        try expect(!received.businessApplied && !received.duplicate && received.selectedReferences.isEmpty, "old pending reply imports nothing")
        let repeated = try client.receiveResult(at: originalReply)
        try expect(repeated.duplicate && !repeated.businessApplied, "transport duplicate does not imply completed business")
        try expect(try client.loadSession(oldRequest.requestID).providerBundleID == oldFilesID, "result receipt never migrates provider binding")
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("explicit .noindex fixture directory required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        guard root.path.hasPrefix("/private/tmp/"), root.pathExtension == "noindex", !fm.fileExists(atPath: root.path) else {
            fatalError("fixture must use a new explicit /private/tmp/*.noindex directory")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        try routing(root)
        try discoveryAndNewRequests(root)
        try historicalSessions(root)
        try ocrDiscoveryAndHistoricalSession(root)
        print("PASS provider-consolidation: \(checks) production-path checks; isolated synthetic data only; no provider launch, GUI, live data or smoke test")
    }
}
