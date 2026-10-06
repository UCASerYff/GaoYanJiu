import Foundation
import SwiftUI
import WebKit

private enum PortalBrowserCompatibility {
    // WKWebView on macOS omits the Safari product token from its default user agent.
    // Some legacy Editorial Manager sites therefore reject an otherwise modern
    // WebKit engine before showing the real login form.
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"

    static func configure(_ webView: WKWebView) {
        webView.customUserAgent = safariUserAgent
        webView.allowsBackForwardNavigationGestures = true
    }
}

enum ExtractorRuntime {
    static func configuredWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        if let url = ResearchBundle.bundle.url(forResource: "extractor", withExtension: "js"),
           let script = try? String(contentsOf: url, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(
                source: script,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        PortalBrowserCompatibility.configure(webView)
        return webView
    }

    static func extract(
        from webView: WKWebView,
        publisher: PublisherDefinition,
        completion: @escaping (Result<ExtractionResult, Error>) -> Void
    ) {
        let payload: [String: String] = [
            "id": publisher.id,
            "name": publisher.name,
            "kind": publisher.kind,
            "url": publisher.url,
        ]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            completion(.failure(PortalError.invalidSource))
            return
        }

        let body = """
        if (!globalThis.PaperSignalExtractor) {
            throw new Error("PaperSignal extractor was not loaded");
        }
        return JSON.stringify(await globalThis.PaperSignalExtractor.extract(JSON.parse(sourceJSON)));
        """

        webView.callAsyncJavaScript(
            body,
            arguments: ["sourceJSON": payloadJSON],
            in: nil,
            in: .page
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let value):
                    guard let json = value as? String, let data = json.data(using: .utf8) else {
                        completion(.failure(PortalError.invalidResponse))
                        return
                    }
                    do {
                        completion(.success(try JSONDecoder().decode(ExtractionResult.self, from: data)))
                    } catch {
                        completion(.failure(error))
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }
}

enum PortalError: LocalizedError {
    case invalidSource
    case invalidResponse
    case invalidAddress
    case noPapers
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidSource: AppLocalization.text("投稿来源配置无效。")
        case .invalidResponse: AppLocalization.text("网页返回了无法识别的数据。")
        case .invalidAddress: AppLocalization.text("请输入有效的投稿网站地址。")
        case .noPapers: AppLocalization.text("当前页面尚未识别到完整的稿件标题和状态。请打开稿件列表或详情，页面加载完成后可重试。")
        case .timedOut: AppLocalization.text("网页加载超时，登录可能已失效。")
        }
    }
}

@MainActor
final class PortalBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let publisher: PublisherDefinition
    let webView: WKWebView

    @Published var address: String
    @Published var isLoading = false
    @Published var isExtracting = false
    @Published var statusMessage = AppLocalization.text("请登录出版商账号，系统会在稿件列表出现后自动导入。")
    @Published var importedCount = 0
    @Published var changedCount = 0
    @Published var hasSavedCredential = false
    @Published private(set) var savedCredentials: [PortalCredential] = []
    @Published var selectedCredentialID: String?
    @Published var credentialMessage = ""

    private let store: PaperStore
    private var credentialScopeURL: String
    private var lastImportedSignature: Data?
    private var scanTimer: Timer?
    private var navigationGeneration = 0
    private var pendingCredentialLogin = false
    private var activeCredential: PortalCredential?
    private var credentialLoginAttempt = 0
    private var didTrySavedLoginURL = false

    init(publisher: PublisherDefinition, store: PaperStore) {
        self.publisher = publisher
        self.store = store
        self.address = publisher.url
        self.credentialScopeURL = publisher.url
        self.webView = ExtractorRuntime.configuredWebView()
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        refreshCredentialAvailability()
        // Frame navigation and SPA updates do not always trigger didFinish on the main frame.
        scanTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            Task { @MainActor [weak self] in
                guard let self, self.webView.window != nil, !self.isLoading else { return }
                self.importCurrentPage(userInitiated: false)
            }
        }
        loadAddress()
    }

    deinit {
        scanTimer?.invalidate()
    }

    func loadAddress() {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "https://\(value)" }
        guard let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            statusMessage = PortalError.invalidAddress.localizedDescription
            return
        }
        address = url.absoluteString
        credentialScopeURL = url.absoluteString
        refreshCredentialAvailability()
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    var savedCredential: PortalCredential? {
        if let selectedCredentialID,
           let selected = savedCredentials.first(where: { $0.id == selectedCredentialID }) {
            return selected
        }
        return savedCredentials.first
    }

    func saveCredential(username: String, password: String) -> Bool {
        do {
            let credential = PortalCredential(
                username: username,
                password: password,
                loginURL: webView.url?.absoluteString ?? address
            )
            try PortalCredentialStore.save(
                credential,
                key: credentialKey
            )
            selectedCredentialID = credential.id
            refreshCredentialAvailability()
            credentialMessage = AppLocalization.format("账号 %@ 已安全保存到 macOS 钥匙串", credential.username)
            return true
        } catch {
            credentialMessage = AppLocalization.format("保存失败：%@", error.localizedDescription)
            return false
        }
    }

    func deleteSavedCredential(credentialID: String? = nil) {
        let targetID = credentialID ?? selectedCredentialID ?? savedCredentials.first?.id
        guard let targetID else { return }
        let username = savedCredentials.first(where: { $0.id == targetID })?.username ?? targetID
        PortalCredentialStore.delete(key: credentialKey, credentialID: targetID)
        pendingCredentialLogin = false
        activeCredential = nil
        selectedCredentialID = nil
        refreshCredentialAvailability()
        credentialMessage = AppLocalization.format("已删除账号 %@", username)
    }

    func oneClickLogin(credentialID: String? = nil) {
        if let credentialID { selectedCredentialID = credentialID }
        guard let credential = savedCredential else {
            credentialMessage = AppLocalization.text("尚未保存该投稿门户的登录信息")
            refreshCredentialAvailability()
            return
        }
        pendingCredentialLogin = true
        activeCredential = credential
        credentialLoginAttempt = 0
        didTrySavedLoginURL = false
        credentialMessage = AppLocalization.format("正在使用账号 %@ 填写登录信息…", credential.username)
        performCredentialLogin(credential)
    }

    func importCurrentPage(userInitiated: Bool = true) {
        guard !isExtracting else { return }
        isExtracting = true
        if userInitiated { statusMessage = AppLocalization.text("正在读取当前页面…") }

        let generation = navigationGeneration
        ExtractorRuntime.extract(from: webView, publisher: publisher) { [weak self] result in
            guard let self else { return }
            self.isExtracting = false
            guard self.navigationGeneration == generation else { return }
            switch result {
            case .success(let extraction) where !extraction.papers.isEmpty:
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                var signature = Data(extraction.url.utf8)
                signature.append((try? encoder.encode(extraction.papers)) ?? Data())
                if !userInitiated, signature == self.lastImportedSignature { return }
                let outcome = self.store.merge(extraction, publisher: self.publisher)
                if outcome.importedCount > 0 { self.lastImportedSignature = signature }
                self.importedCount = outcome.importedCount
                self.changedCount = outcome.changedCount
                if outcome.changedCount > 0 {
                    self.statusMessage = AppLocalization.format("已导入 %d 篇论文，其中 %d 篇状态有更新。", outcome.importedCount, outcome.changedCount)
                } else {
                    self.statusMessage = AppLocalization.format("已自动导入 %d 篇论文，数据只保存在这台 Mac。", outcome.importedCount)
                }
            case .success:
                if userInitiated {
                    self.statusMessage = PortalError.noPapers.localizedDescription
                } else if self.importedCount == 0 {
                    self.statusMessage = AppLocalization.text("等待登录完成并打开稿件列表…")
                }
            case .failure(let error):
                if userInitiated {
                    self.statusMessage = AppLocalization.format("读取失败：%@", error.localizedDescription)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        navigationGeneration += 1
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        address = webView.url?.absoluteString ?? address
        navigationGeneration += 1
        let generation = navigationGeneration
        refreshCredentialAvailability()
        if pendingCredentialLogin, let credential = activeCredential ?? savedCredential {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.pendingCredentialLogin else { return }
                self.performCredentialLogin(credential)
            }
        }
        statusMessage = importedCount > 0 ? statusMessage : AppLocalization.text("页面已打开，正在等待稿件列表…")
        for delay in [1.0, 3.0, 6.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.navigationGeneration == generation else { return }
                self.importCurrentPage(userInitiated: false)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
        statusMessage = AppLocalization.format("网页无法打开：%@", error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame == nil else {
            decisionHandler(.allow)
            return
        }

        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            decisionHandler(.cancel)
            return
        }

        // Editorial Manager and several SSO providers use target="_blank" or
        // window.open(). Keep those navigations inside the portal window so the
        // shared WebKit cookie session and the import workflow remain intact.
        webView.load(navigationAction.request)
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let requestURL = navigationAction.request.url {
            webView.load(URLRequest(url: requestURL))
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: AppLocalization.text("确定"))
        present(alert, in: webView, completionHandler: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: AppLocalization.text("确定"))
        alert.addButton(withTitle: AppLocalization.text("取消"))
        present(alert, in: webView) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: AppLocalization.text("确定"))
        alert.addButton(withTitle: AppLocalization.text("取消"))
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        present(alert, in: webView) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    private func present(
        _ alert: NSAlert,
        in webView: WKWebView,
        completionHandler: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completionHandler)
        } else {
            completionHandler(alert.runModal())
        }
    }

    private func present(_ alert: NSAlert, in webView: WKWebView, completionHandler: @escaping () -> Void) {
        present(alert, in: webView) { _ in completionHandler() }
    }

    private var credentialKey: String {
        PortalCredentialStore.key(for: credentialScopeURL, publisher: publisher)
    }

    private func refreshCredentialAvailability() {
        let previousSelection = selectedCredentialID
        let visiblePageKey = PortalCredentialStore.key(
            for: webView.url?.absoluteString ?? address,
            publisher: publisher
        )
        if visiblePageKey != credentialKey {
            for legacyCredential in PortalCredentialStore.loadAll(key: visiblePageKey) {
                try? PortalCredentialStore.save(legacyCredential, key: credentialKey)
            }
        }
        savedCredentials = PortalCredentialStore.loadAll(key: credentialKey)
        hasSavedCredential = !savedCredentials.isEmpty
        if let previousSelection,
           savedCredentials.contains(where: { $0.id == previousSelection }) {
            selectedCredentialID = previousSelection
        } else {
            selectedCredentialID = savedCredentials.first?.id
        }
    }

    private func performCredentialLogin(_ credential: PortalCredential) {
        guard pendingCredentialLogin else { return }
        credentialLoginAttempt += 1
        let script = """
        const visible = (element) => {
            if (!element || element.disabled || element.type === "hidden") return false;
            const style = element.ownerDocument.defaultView.getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.display !== "none" && style.visibility !== "hidden" && rect.width > 0 && rect.height > 0;
        };

        const roots = [];
        const collectRoots = (root) => {
            if (!root || roots.includes(root)) return;
            roots.push(root);
            for (const element of root.querySelectorAll("*")) {
                if (element.shadowRoot) collectRoots(element.shadowRoot);
                if (element.tagName === "IFRAME") {
                    try { collectRoots(element.contentDocument); } catch (_) {}
                }
            }
        };
        collectRoots(document);
        const queryAll = (selector) => roots.flatMap((root) => [...root.querySelectorAll(selector)]);

        const inputs = queryAll("input").filter(visible);
        const password = inputs.find((input) => input.type === "password");
        const username = inputs.find((input) => {
            const marker = `${input.name} ${input.id} ${input.autocomplete} ${input.placeholder} ${input.getAttribute("aria-label") || ""}`.toLowerCase();
            return input !== password && (input.type === "email" || /user|login|account|email|e-mail|identifier/.test(marker));
        }) || inputs.find((input) => input !== password && ["text", "email"].includes(input.type));
        if (!username && !password) return "none";

        const setValue = (input, value) => {
            if (!input) return;
            input.removeAttribute("readonly");
            input.focus();
            const view = input.ownerDocument.defaultView;
            const prototype = view.HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
            setter ? setter.call(input, value) : (input.value = value);
            if (view.InputEvent) {
                input.dispatchEvent(new view.InputEvent("input", { bubbles: true, inputType: "insertText", data: value }));
            } else {
                input.dispatchEvent(new view.Event("input", { bubbles: true }));
            }
            input.dispatchEvent(new view.Event("change", { bubbles: true }));
            input.dispatchEvent(new view.KeyboardEvent("keyup", { bubbles: true, key: "Unidentified" }));
            input.blur();
        };
        setValue(username, usernameValue);
        setValue(password, passwordValue);

        const form = password?.form || username?.form;
        const candidates = [
            ...(form ? [...form.querySelectorAll('button, input[type="submit"], input[type="button"], input[type="image"], [role="button"]')] : []),
            ...queryAll('button, input[type="submit"], input[type="button"], input[type="image"], [role="button"], a')
        ];
        const submit = candidates.find((element) =>
                visible(element) && element.matches('button[type="submit"], input[type="submit"], input[type="image"]'))
            || candidates.find((element) =>
                visible(element) && /log\\s*in|sign\\s*in|continue|next|submit|登录|登入|继续|下一步/i.test(element.innerText || element.value || element.getAttribute("aria-label") || "")
            );

        let submitted = false;
        if (submit) {
            submit.click();
            submitted = true;
        } else if (form?.requestSubmit) {
            form.requestSubmit();
            submitted = true;
        }
        if (password) return submitted ? "password-submitted" : "password-filled";
        return submitted ? "username-submitted" : "username-filled";
        """
        webView.callAsyncJavaScript(
            script,
            arguments: ["usernameValue": credential.username, "passwordValue": credential.password],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                let stage = value as? String ?? "none"
                if stage == "password-submitted" {
                    self.pendingCredentialLogin = false
                    self.activeCredential = nil
                    self.credentialMessage = AppLocalization.format("已使用账号 %@ 提交登录", credential.username)
                } else if stage == "password-filled" {
                    self.pendingCredentialLogin = false
                    self.activeCredential = nil
                    self.credentialMessage = AppLocalization.format("已为账号 %@ 填写密码，请点击网页中的登录按钮", credential.username)
                } else if stage == "username-submitted" || stage == "username-filled" {
                    self.credentialMessage = AppLocalization.format("已填写账号 %@，正在等待密码页面…", credential.username)
                    self.scheduleCredentialRetry(credential)
                } else {
                    self.continueCredentialLoginAfterMissingForm(credential)
                }
            case .failure(let error):
                self.pendingCredentialLogin = false
                self.activeCredential = nil
                self.credentialMessage = AppLocalization.format("一键登录失败：%@", error.localizedDescription)
            }
        }
    }

    private func scheduleCredentialRetry(_ credential: PortalCredential) {
        guard pendingCredentialLogin else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.pendingCredentialLogin else { return }
            self.performCredentialLogin(credential)
        }
    }

    private func continueCredentialLoginAfterMissingForm(_ credential: PortalCredential) {
        if credentialLoginAttempt < 4 {
            credentialMessage = AppLocalization.format("正在等待账号 %@ 的登录表单…", credential.username)
            scheduleCredentialRetry(credential)
            return
        }

        if !didTrySavedLoginURL,
           let loginURL = credential.loginURL,
           let url = URL(string: loginURL),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           normalizedPageURL(loginURL) != normalizedPageURL(webView.url?.absoluteString) {
            didTrySavedLoginURL = true
            credentialLoginAttempt = 0
            credentialMessage = AppLocalization.format("正在打开账号 %@ 保存时的登录页面…", credential.username)
            webView.load(URLRequest(url: url))
            return
        }

        pendingCredentialLogin = false
        activeCredential = nil
        credentialMessage = AppLocalization.text("当前页面未找到可填写的登录表单，请先打开登录页面后重试")
    }

    private func normalizedPageURL(_ value: String?) -> String? {
        guard let value, var components = URLComponents(string: value) else { return nil }
        components.fragment = nil
        components.query = nil
        components.host = components.host?.lowercased()
        return components.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

struct PortalWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
final class PortalRefreshCoordinator {
    typealias Progress = (_ completed: Int, _ total: Int, _ portal: PortalAccount) -> Void
    typealias ResultHandler = (_ portal: PortalAccount, _ result: ExtractionResult) -> Void
    typealias FailureHandler = (_ portal: PortalAccount, _ message: String) -> Void

    private var queue: [PortalAccount] = []
    private var total = 0
    private var completed = 0
    private var failures = 0
    private var activeLoader: PortalHeadlessLoader?
    private var progress: Progress?
    private var resultHandler: ResultHandler?
    private var failureHandler: FailureHandler?
    private var completion: ((Int) -> Void)?

    func refresh(
        portals: [PortalAccount],
        progress: @escaping Progress,
        result: @escaping ResultHandler,
        failure: @escaping FailureHandler,
        completion: @escaping (Int) -> Void
    ) {
        queue = portals
        total = portals.count
        self.progress = progress
        resultHandler = result
        failureHandler = failure
        self.completion = completion
        advance()
    }

    private func advance() {
        guard !queue.isEmpty else {
            completion?(failures)
            completion = nil
            activeLoader = nil
            return
        }

        let portal = queue.removeFirst()
        progress?(completed, total, portal)
        let loader = PortalHeadlessLoader(portal: portal) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let extraction):
                self.resultHandler?(portal, extraction)
            case .failure(let error):
                self.failures += 1
                self.failureHandler?(portal, error.localizedDescription)
            }
            self.completed += 1
            self.activeLoader = nil
            self.advance()
        }
        activeLoader = loader
        loader.start()
    }
}

@MainActor
private final class PortalHeadlessLoader: NSObject, WKNavigationDelegate {
    private let portal: PortalAccount
    private let webView: WKWebView
    private let completion: (Result<ExtractionResult, Error>) -> Void
    private var finished = false
    private var generation = 0

    init(portal: PortalAccount, completion: @escaping (Result<ExtractionResult, Error>) -> Void) {
        self.portal = portal
        self.completion = completion
        self.webView = ExtractorRuntime.configuredWebView()
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
        guard let url = URL(string: portal.url) else {
            finish(.failure(PortalError.invalidAddress))
            return
        }
        webView.load(URLRequest(url: url))
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.finish(.failure(PortalError.timedOut))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        generation += 1
        let currentGeneration = generation
        for (index, delay) in [1.5, 4.0, 8.0, 13.0].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.finished, self.generation == currentGeneration else { return }
                self.attempt(isLast: index == 3)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    private func attempt(isLast: Bool) {
        ExtractorRuntime.extract(from: webView, publisher: portal.publisher) { [weak self] result in
            guard let self, !self.finished else { return }
            switch result {
            case .success(let extraction) where !extraction.papers.isEmpty:
                self.finish(.success(extraction))
            case .failure(let error) where isLast:
                self.finish(.failure(error))
            case .success where isLast:
                self.finish(.failure(PortalError.noPapers))
            default:
                break
            }
        }
    }

    private func finish(_ result: Result<ExtractionResult, Error>) {
        guard !finished else { return }
        finished = true
        webView.stopLoading()
        completion(result)
    }
}
