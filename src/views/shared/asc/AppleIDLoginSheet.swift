import SwiftUI
import WebKit

struct AppleIDLoginSheet: View {
    var subtitle: String = "Sign in to App Store Connect to authenticate your Apple ID session."
    var onSessionCaptured: (IrisSession) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var browserID = UUID()
    @State private var isResettingBrowser = false
    @State private var validationMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in with Apple ID")
                        .font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Use Another Apple ID") {
                    isResettingBrowser = true
                    Task { @MainActor in
                        await ASCWebView.resetBrowser()
                        isLoading = true
                        browserID = UUID()
                        isResettingBrowser = false
                    }
                }
                .disabled(isResettingBrowser)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            if let validationMessage {
                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            ZStack {
                if !isResettingBrowser {
                    ASCWebView(
                        isLoading: $isLoading,
                        validationMessage: $validationMessage,
                        onSessionCaptured: { session in
                            guard !isResettingBrowser else { return }
                            irisLog("AppleIDLoginSheet: onSessionCaptured called, \(session.cookies.count) cookies")
                            onSessionCaptured(session)
                            dismiss()
                        }
                    )
                    .id(browserID)
                }

                if isLoading || isResettingBrowser {
                    ProgressView("Loading App Store Connect…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background.opacity(0.8))
                }
            }
        }
        .frame(width: 520, height: 620)
        .onAppear { irisLog("AppleIDLoginSheet: sheet appeared") }
    }
}

// MARK: - WKWebView Wrapper

struct ASCWebView: NSViewRepresentable {
    @Binding var isLoading: Bool
    @Binding var validationMessage: String?
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
    private static let persistentStoreID = UUID(uuidString: "6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!

    @MainActor static func resetBrowser() async {
        await WKWebsiteDataStore(forIdentifier: persistentStoreID).removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.persistentStoreID)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.startPolling()

        if let url = URL(string: "https://appstoreconnect.apple.com") {
            irisLog("ASCWebView: loading initial URL \(url)")
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

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
        let parent: ASCWebView
        weak var webView: WKWebView?
        private var hasCapture = false
        private var gate = ASCWebCaptureGate()
        private var pollTimer: Timer?
        private var validationTask: Task<Void, Never>?
        private var nextValidationAt = Date.distantPast

        init(parent: ASCWebView) { self.parent = parent }

        deinit { pollTimer?.invalidate(); validationTask?.cancel() }

        func cancel() {
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
            guard !hasCapture, let webView, !webView.isLoading,
                  ASCWebAuthentication.isAppStoreConnectURL(webView.url),
                  Date() >= nextValidationAt,
                  let token = gate.begin() else { return }

            validationTask = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
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
                    let result: Any = try await withCheckedThrowingContinuation { continuation in
                        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                            continuation.resume(with: result)
                        }
                    }
                    guard self.gate.accepts(token), !Task.isCancelled,
                          ASCWebAuthentication.isAppStoreConnectURL(webView.url) else { return }
                    guard let result = result as? [String: Any],
                          let status = result["status"] as? Int,
                          let body = result["body"] as? String else {
                        throw ASCWebAuthenticationError.invalidResponse
                    }
                    let email = try ASCWebAuthentication.authenticatedEmail(statusCode: status, data: Data(body.utf8))
                    let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                            continuation.resume(returning: cookies)
                        }
                    }
                    guard self.gate.accepts(token), !Task.isCancelled else { return }
                    let now = Date()
                    let appleCookies = cookies.filter { cookie in
                        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        return (domain == "apple.com" || domain.hasSuffix(".apple.com"))
                            && (cookie.expiresDate.map { $0 > now } ?? true)
                    }
                    let session = IrisSession(cookies: appleCookies.map {
                        .init(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                              expires: $0.expiresDate, secure: $0.isSecure, httpOnly: $0.isHTTPOnly)
                    }, email: email, capturedAt: now)
                    guard !ASCWebAuthentication.cookieHeader(from: session.cookies).isEmpty else {
                        throw ASCWebAuthenticationError.notAuthenticated
                    }
                    self.parent.validationMessage = "Apple-Anmeldung wird für Blitz und ASC geprüft …"
                    // The official importer validates the exact CLI transport and
                    // stores the accepted bundle before we report success.
                    try await ASCWebSessionCLIImporter().importSession(session)
                    guard self.gate.accepts(token), !Task.isCancelled else { return }
                    self.hasCapture = true
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                    self.gate.finish(token)
                    self.parent.validationMessage = nil
                    self.parent.onSessionCaptured(session)
                } catch {
                    guard self.gate.accepts(token), !Task.isCancelled else { return }
                    self.gate.finish(token)
                    self.nextValidationAt = Date().addingTimeInterval(10)
                    // No response bodies, cookie values, or raw subprocess errors
                    // are logged or displayed by the login sheet.
                    self.parent.validationMessage = (error as? ASCWebAuthenticationError)?.errorDescription
                        ?? (error as? ASCWebSessionCLIImporter.ImportError)?.errorDescription
                        ?? "Die Anmeldung konnte noch nicht für ASC übernommen werden. Bitte schließe die Apple-Anmeldung ab; Blitz prüft sie erneut."
                    irisLog("Apple web session validation failed; login remains open")
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            gate.invalidate()
            validationTask?.cancel()
            validationTask = nil
            nextValidationAt = .distantPast
            parent.validationMessage = nil
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            pollSession()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            navigationFailed()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            navigationFailed()
        }

        private func navigationFailed() {
            parent.isLoading = false
            parent.validationMessage = ASCWebAuthenticationError.transport.errorDescription
        }
    }
}
