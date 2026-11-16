// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI
import WebKit

struct AppleIDLoginSheet: View {
    var subtitle: String = L10n.tr("Melde dich bei App Store Connect an, um deinen Apple-Account mit Blitz Neo zu verbinden.")
    var requireDeveloperPortal = false
    var onSessionCaptured: (IrisSession) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var browserID = UUID()
    @State private var loadProblem: String?
    @State private var validationMessage: String?
    @State private var browserControl = ASCWebLoginControl()

    var body: some View {
        VStack(spacing: 0) {
            BlitzSetupHeader(L10n.tr("Mit Apple-Account anmelden"), subtitle: requireDeveloperPortal
                ? L10n.tr("App Store Connect und Developer-Portal für denselben Anbieter bestätigen.")
                : subtitle)
                .padding(24)

            Divider()

            AppleIDLoginStatusView(isLoading: isLoading, loadProblem: loadProblem,
                                   validationMessage: validationMessage)

            browser

            Divider()

            HStack {
                Button(L10n.tr("Abbrechen")) { browserControl.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.tr("Erneut laden")) { reloadBrowser() }
                    .help(L10n.tr("Lädt das Anmeldefenster neu und behält die bestehende Browser-Anmeldung bei."))
                Button(L10n.tr("Anderen Apple-Account verwenden")) {
                    browserControl.cancel()
                    ASCWebView.useFreshBrowserStore()
                    reloadBrowser()
                }
            }
            .padding(24)
        }
        .frame(width: 560, height: 660)
        .onAppear { irisLog("AppleIDLoginSheet: sheet appeared") }
        .onDisappear { browserControl.cancel() }
    }

    private var browser: some View {
        let generation = browserID
        return ASCWebView(isLoading: $isLoading, loadProblem: $loadProblem,
                          validationMessage: $validationMessage,
                          requireDeveloperPortal: requireDeveloperPortal,
                          control: browserControl) { session in
            guard browserID == generation else { return }
            onSessionCaptured(session)
            dismiss()
        }
        .id(generation)
    }

    private func reloadBrowser() {
        browserControl.cancel()
        validationMessage = nil
        loadProblem = nil
        isLoading = true
        browserID = UUID()
    }
}

/// Progress never obscures or intercepts Apple's sign-in form. A page may be
/// usable while WebKit is still waiting for a slow secondary resource.
struct AppleIDLoginStatusView: View {
    var isLoading: Bool
    var loadProblem: String?
    var validationMessage: String?

    var body: some View {
        if isLoading || loadProblem != nil || validationMessage != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let loadProblem {
                    Label(loadProblem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if isLoading {
                    ProgressView(L10n.tr("Apple-Anmeldeseite wird geladen …"))
                        .controlSize(.small)
                }
                if let validationMessage {
                    Text(validationMessage).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - WKWebView Wrapper

@MainActor
final class ASCWebLoginControl {
    weak var coordinator: ASCWebView.Coordinator?

    func cancel() {
        coordinator?.cancel()
        coordinator?.webView?.navigationDelegate = nil
        coordinator?.webView?.stopLoading()
    }
}

struct ASCWebView: NSViewRepresentable {
    @Binding var isLoading: Bool
    @Binding var loadProblem: String?
    @Binding var validationMessage: String?
    var requireDeveloperPortal = false
    var control: ASCWebLoginControl
    var onSessionCaptured: (IrisSession) -> Void

    // A stable, app-scoped (not shared with Safari) *persistent* data store.
    // This used to be `.nonPersistent()`, which discards all cookies —
    // including Apple's own "remember this device" trust cookie — the
    // instant the sheet closes. That forced Apple ID's 2FA to re-verify
    // (and re-show "Trust This Browser") on *every single* sign-in, and
    // checking that box could never have any effect, since there was
    // nothing left afterward for it to persist into. Using a persistent,
    // identifier-scoped store lets the WebView remember the ASC session
    // (and Apple's device trust) across launches like a normal browser
    // would, while keeping it fully isolated from the user's actual Safari
    // data. A captured cookie is validated before it is reused outside WebKit.
    @MainActor static func useFreshBrowserStore() {
        // A stalled cleanup callback must not hold the new login hostage. The
        // cleanup targets only the OLD store, so late completion cannot erase
        // cookies from the newly opened login. Native/CLI sessions are untouched.
        let previous = ASCWebLoginStoreIdentity.rotate()
        WKWebsiteDataStore(forIdentifier: previous).removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: ASCWebLoginStoreIdentity.current())

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        control.coordinator = context.coordinator
        context.coordinator.startPolling()

        if let url = URL(string: "https://appstoreconnect.apple.com") {
            irisLog("ASCWebView: loading initial URL \(url)")
            context.coordinator.loadPage(url, in: webView)
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.cancel()
        nsView.navigationDelegate = nil
        nsView.stopLoading()
    }

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ASCWebView
        weak var webView: WKWebView?
        private var hasCapture = false
        private var gate = ASCWebCaptureGate()
        private var pollTimer: Timer?
        private var validationTask: Task<Void, Never>?
        private var nextValidationAt = Date.distantPast
        private var expectedIdentity: ASCWebAuthentication.Identity?
        private var navigationState = ASCWebLoginNavigation()
        private var activeNavigation: WKNavigation?
        private var navigationDeadline: Task<Void, Never>?
        var navigationTimeout: Duration = .seconds(30)

        init(parent: ASCWebView) { self.parent = parent }

        deinit { pollTimer?.invalidate(); validationTask?.cancel(); navigationDeadline?.cancel() }

        func cancel() {
            navigationState.cancel()
            navigationDeadline?.cancel()
            navigationDeadline = nil
            gate.cancel()
            pollTimer?.invalidate()
            pollTimer = nil
            validationTask?.cancel()
            validationTask = nil
        }

        func startPolling() {
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollSession() }
            }
        }

        private func pollSession() {
            // Persisted myacinfo alone does not prove that sign-in or 2FA has
            // completed. Never capture from idmsa or while a redirect is loading.
            guard !hasCapture, navigationState.canValidate, let webView, !webView.isLoading,
                  (ASCWebAuthentication.isAppStoreConnectURL(webView.url)
                    || (parent.requireDeveloperPortal && expectedIdentity != nil
                        && ASCWebAuthentication.isDeveloperPortalURL(webView.url))),
                  Date() >= nextValidationAt,
                  let token = gate.begin() else { return }

            validationTask = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                defer { self.gate.finish(token) }
                do {
                    let identity: ASCWebAuthentication.Identity
                    if ASCWebAuthentication.isAppStoreConnectURL(webView.url) {
                        let script = """
                        const controller = new AbortController();
                        const timer = setTimeout(() => controller.abort(), 15000);
                        try {
                            const response = await fetch('/olympus/v1/session', {
                                credentials: 'include', cache: 'no-store', signal: controller.signal,
                                headers: { 'Accept': 'application/json' }
                            });
                            return {status: response.status, body: await response.text()};
                        } finally { clearTimeout(timer); }
                        """
                        let result: Any = try await ASCWebCallback.wait(timeout: 20) { completion in
                            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                                completion(result)
                            }
                        }
                        guard self.gate.accepts(token), !Task.isCancelled,
                              ASCWebAuthentication.isAppStoreConnectURL(webView.url) else { return }
                        guard let result = result as? [String: Any],
                              let status = result["status"] as? Int,
                              let body = result["body"] as? String else {
                            throw ASCWebAuthenticationError.invalidResponse
                        }
                        identity = try ASCWebAuthentication.authenticatedIdentity(statusCode: status, data: Data(body.utf8))
                        if let expected = self.expectedIdentity, expected != identity {
                            throw ASCWebAuthenticationError.accountChanged
                        }
                        self.expectedIdentity = identity
                    } else {
                        guard let expected = self.expectedIdentity else { throw ASCWebAuthenticationError.invalidResponse }
                        identity = expected
                    }
                    let cookies: [HTTPCookie] = try await ASCWebCallback.wait(timeout: 10) { completion in
                        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                            completion(.success(cookies))
                        }
                    }
                    guard self.gate.accepts(token), !Task.isCancelled else { return }
                    let now = Date()
                    let appleCookies = cookies.filter { cookie in
                        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        return (domain == "apple.com" || domain.hasSuffix(".apple.com"))
                            && (cookie.expiresDate.map { $0 > now } ?? true)
                    }
                    var session = IrisSession(cookies: appleCookies.map {
                        .init(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                              expires: $0.expiresDate, secure: $0.isSecure, httpOnly: $0.isHTTPOnly)
                    }, email: identity.email, capturedAt: now, providerId: identity.providerId,
                        publicProviderId: identity.publicProviderId, providerName: identity.providerName)
                    guard !ASCWebAuthentication.cookieHeader(from: session.cookies).isEmpty else {
                        throw ASCWebAuthenticationError.notAuthenticated
                    }
                    self.parent.validationMessage = L10n.tr("Apple-Anmeldung wird für Blitz Neo und ASC geprüft …")
                    let evidence = try await ASCWebSessionCLIImporter().importSession(session)
                    guard self.gate.accepts(token), !Task.isCancelled else { return }
                    session.importEvidence = evidence
                    if !evidence.satisfies(requireDeveloperPortal: self.parent.requireDeveloperPortal) {
                        self.gate.finish(token)
                        self.nextValidationAt = Date().addingTimeInterval(10)
                        if ASCWebAuthentication.isAppStoreConnectURL(webView.url) {
                            self.loadPage(URL(string: "https://developer.apple.com/account/")!, in: webView)
                        }
                        self.parent.validationMessage = L10n.tr("App Store Connect ist bestätigt. Bitte die Anmeldung im Developer-Portal für denselben Anbieter abschließen. Eine Vertragszustimmung wird hier nicht automatisch erteilt.")
                        return
                    }
                    self.hasCapture = true
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                    self.gate.finish(token)
                    self.parent.validationMessage = nil
                    self.parent.onSessionCaptured(session)
                } catch {
                    guard self.gate.accepts(token), !Task.isCancelled else { return }
                    if error is ASCWebCallbackError {
                        self.failCurrentNavigation(L10n.tr("Das Anmeldefenster antwortet nicht. Bitte erneut laden; die bestehende Browser-Anmeldung bleibt erhalten."))
                        return
                    }
                    self.gate.finish(token)
                    self.nextValidationAt = Date().addingTimeInterval(10)
                    // No response bodies, cookie values, or raw subprocess errors
                    // are logged or displayed by the login sheet.
                    self.parent.validationMessage = (error as? ASCWebAuthenticationError)?.errorDescription
                        ?? (error as? ASCWebSessionCLIImporter.ImportError)?.errorDescription
                        ?? L10n.tr("Die Anmeldung konnte noch nicht für ASC übernommen werden. Bitte schließe die Apple-Anmeldung ab; Blitz Neo prüft sie erneut.")
                    irisLog("Apple web session validation failed; login remains open")
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            // The initial deadline is armed before load(), including WebContent
            // startup that never produces a didStart callback.
            if navigation === activeNavigation, navigationState.isLoading { return }
            beginNavigation(navigation)
        }

        func loadPage(_ url: URL, in webView: WKWebView) {
            beginNavigation(nil)
            activeNavigation = webView.load(URLRequest(url: url, timeoutInterval: 30))
        }

        func beginNavigation(_ navigation: WKNavigation?) {
            guard let generation = navigationState.start() else { return }
            activeNavigation = navigation
            navigationDeadline?.cancel()
            gate.invalidate()
            validationTask?.cancel()
            validationTask = nil
            nextValidationAt = .distantPast
            parent.validationMessage = nil
            parent.loadProblem = nil
            parent.isLoading = true
            let timeout = navigationTimeout
            navigationDeadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, self.navigationState.token == generation,
                      self.navigationState.isLoading else { return }
                self.failCurrentNavigation(L10n.tr("Die Apple-Anmeldeseite lädt zu lange. Bitte die Verbindung prüfen und erneut laden."))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === activeNavigation, let generation = navigationState.token,
                  navigationState.finish(generation) else { return }
            navigationDeadline?.cancel()
            navigationDeadline = nil
            parent.isLoading = false
            pollSession()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            navigationFailed(navigation)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            navigationFailed(navigation)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            failCurrentNavigation(L10n.tr("Das Anmeldefenster wurde unerwartet beendet. Bitte erneut laden; die bestehende Browser-Anmeldung bleibt erhalten."))
        }

        private func navigationFailed(_ navigation: WKNavigation?) {
            guard navigation === activeNavigation, navigationState.isLoading else { return }
            failCurrentNavigation(ASCWebAuthenticationError.transport.errorDescription!)
        }

        private func failCurrentNavigation(_ message: String) {
            guard let generation = navigationState.token, navigationState.fail(generation) else { return }
            navigationDeadline?.cancel()
            navigationDeadline = nil
            gate.invalidate()
            validationTask?.cancel()
            validationTask = nil
            webView?.stopLoading()
            parent.isLoading = false
            parent.validationMessage = nil
            parent.loadProblem = message
        }
    }
}
