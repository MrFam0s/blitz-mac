import Foundation
import Testing
@testable import Blitz

@Test func webAuthenticationRequiresSuccessfulAppleSessionResponse() throws {
    let valid = Data(#"{"user":{"emailAddress":" user@example.com "}}"#.utf8)
    #expect(try ASCWebAuthentication.authenticatedEmail(statusCode: 200, data: valid) == "user@example.com")
    #expect(throws: ASCWebAuthenticationError.self) {
        try ASCWebAuthentication.authenticatedEmail(statusCode: 401, data: valid)
    }
    #expect(throws: ASCWebAuthenticationError.self) {
        try ASCWebAuthentication.authenticatedEmail(statusCode: 403, data: valid)
    }
    for body in ["<html>Sign in</html>", "{}", #"{"user":{"emailAddress":" "}}"#] {
        #expect(throws: ASCWebAuthenticationError.self) {
            try ASCWebAuthentication.authenticatedEmail(statusCode: 200, data: Data(body.utf8))
        }
    }
}

@Test func webAuthenticationWaitsForActualASCOrigin() {
    #expect(ASCWebAuthentication.isAppStoreConnectURL(URL(string: "https://appstoreconnect.apple.com/apps")))
    for url in [nil, URL(string: "https://idmsa.apple.com/appleauth/auth/signin"),
                URL(string: "http://appstoreconnect.apple.com"),
                URL(string: "https://appstoreconnect.apple.com.example.org"),
                URL(string: "https://appstoreconnect.apple.com:8443")] {
        #expect(!ASCWebAuthentication.isAppStoreConnectURL(url))
    }
}

@Test func webAuthenticationCookiesRespectOriginPathAndExpiry() {
    let now = Date(timeIntervalSince1970: 100)
    let cookies: [IrisSession.IrisCookie] = [
        .init(name: "asc", value: "valid", domain: ".appstoreconnect.apple.com", path: "/"),
        .init(name: "sameName", value: "idmsa-only", domain: "idmsa.apple.com", path: "/"),
        .init(name: "other", value: "bad", domain: "notapple.com", path: "/"),
        .init(name: "expired", value: "old", domain: ".apple.com", path: "/", expires: now),
        .init(name: "path", value: "valid", domain: ".apple.com", path: "/olympus"),
        .init(name: "wrongPath", value: "bad", domain: ".apple.com", path: "/olym"),
        .init(name: "DES", value: "has spaces", domain: ".apple.com", path: "/"),
        .init(name: "injection", value: "bad\r\nHeader: value", domain: ".apple.com", path: "/"),
    ]
    let header = ASCWebAuthentication.cookieHeader(from: cookies, now: now)
    #expect(header.contains("asc=valid"))
    #expect(header.hasPrefix("path=valid;"))
    #expect(header.contains(#"DES="has spaces""#))
    for excluded in ["sameName", "other=", "expired", "wrongPath", "injection"] {
        #expect(!header.contains(excluded))
    }
    #expect(ASCWebAuthentication.cookieHeader(from: cookies, for: URL(string: "https://example.org")!).isEmpty)
}

@Test func webAuthenticationDoesNotAcceptLateOrParallelCapture() throws {
    var gate = ASCWebCaptureGate()
    let firstAttempt = gate.begin()
    let first = try #require(firstAttempt)
    let blockedAttempt = gate.begin()
    #expect(blockedAttempt == nil)
    gate.invalidate() // Navigation or browser reset started while the request ran.
    let secondAttempt = gate.begin()
    let second = try #require(secondAttempt)
    #expect(!gate.accepts(first))
    #expect(gate.accepts(second))
    gate.finish(first) // Stale completion must not release the current request.
    let stillBlockedAttempt = gate.begin()
    #expect(stillBlockedAttempt == nil)
    gate.cancel() // Closing the login sheet must prevent a later success callback.
    #expect(!gate.accepts(second))
    let cancelledAttempt = gate.begin()
    #expect(cancelledAttempt == nil)
}

@Test func webAuthenticationCanRetryFailedValidation() throws {
    var gate = ASCWebCaptureGate()
    let attempt = gate.begin()
    let token = try #require(attempt)
    gate.finish(token)
    #expect(!gate.accepts(token))
    let retry = gate.begin()
    #expect(retry != nil)
}

@Test func webSessionBackfillPreservesCaptureDateAndCookieExpiry() throws {
    let captureDate = Date(timeIntervalSince1970: 10)
    let expires = Date(timeIntervalSince1970: 3600)
    let session = IrisSession(cookies: [
        .init(name: "asc", value: "test", domain: "appstoreconnect.apple.com", path: "/",
              expires: expires, secure: true, httpOnly: false)
    ], email: "user@example.com", capturedAt: captureDate)
    let first = try ASCWebSessionStore.mergedData(storing: session, into: nil)
    let backfill = try ASCWebSessionStore.mergedData(storing: session, into: first)
    #expect(first == backfill)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let store = try decoder.decode(ASCWebSessionStore.self, from: backfill)
    let stored = try #require(store.sessions.values.first)
    #expect(stored.updatedAt == captureDate)
    let cookie = try #require(stored.cookies["https://appstoreconnect.apple.com/"]?.first)
    #expect(cookie.expires == expires)
    #expect(cookie.httpOnly == false)
}

@Test func legacyIrisCookieStillDecodesWithoutNewMetadata() throws {
    let cookie = try JSONDecoder().decode(IrisSession.IrisCookie.self,
        from: Data(#"{"name":"old","value":"test","domain":".apple.com","path":"/"}"#.utf8))
    #expect(cookie.expires == nil)
    #expect(cookie.secure == nil)
    #expect(cookie.httpOnly == nil)
}
