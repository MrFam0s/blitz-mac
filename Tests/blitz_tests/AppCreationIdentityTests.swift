import Foundation
import Testing
@testable import Blitz

private let creationIdentity = AppCreationIdentity(appName: "Club Bundle", bundleId: "org.amosystems.ClubBundle.Widget",
    sku: "ClubBundle-iOS", platform: .iOS, primaryLocale: "de-DE")

private func creationApp(name: String = "Club Bundle", bundleId: String = "org.amosystems.ClubBundle.Widget",
                         sku: String? = "ClubBundle-iOS", locale: String = "de-DE") -> ASCApp {
    ASCApp(id: "app-a", attributes: .init(bundleId: bundleId, name: name, primaryLocale: locale,
        vendorNumber: nil, contentRightsDeclaration: nil, sku: sku), relationships: nil)
}

private func creationVersion(platform: String = "IOS") -> ASCAppStoreVersion {
    ASCAppStoreVersion(id: "version-a", attributes: .init(versionString: "1.0", appStoreState: "PREPARE_FOR_SUBMISSION",
        releaseType: nil, createdDate: nil, copyright: nil, platform: platform))
}

@Test func appCreationIdentityKeepsPublicNameAndTechnicalIdentitySeparate() throws {
    try creationIdentity.validate()
    try creationIdentity.verify(app: creationApp(), versions: [creationVersion()])
    let encoded = try JSONEncoder().encode(creationIdentity)
    #expect(try JSONDecoder().decode(AppCreationIdentity.self, from: encoded) == creationIdentity)
}

@Test(arguments: ["org.amosystems.Übung", "org..ClubBundle", "org.amo_systems.App", "org.example.App!", "org.example.App\n", " org.example.App", "org.example.App."])
func appCreationIdentityRejectsInvalidBundleIDsWithoutRenaming(_ invalid: String) {
    #expect(!AppCreationIdentity.validBundleID(invalid))
    var identity = creationIdentity
    identity.bundleId = invalid
    #expect(throws: AppCreationIdentity.InvalidIdentity.self) { try identity.validate() }
    #expect(identity.bundleId == invalid)
}

@Test(arguments: ["Club Bundle-iOS", "Äpp-iOS", "-Club-iOS", "Club-iOS\n", "Club/iOS", ""])
func appCreationIdentityRejectsInvalidSKU(_ sku: String) {
    var identity = creationIdentity
    identity.sku = sku
    #expect(throws: AppCreationIdentity.InvalidIdentity.self) { try identity.validate() }
}

@Test(arguments: ["A", " App", "App ", "App\nName", String(repeating: "a", count: 31)])
func appCreationIdentityRejectsInvalidPublicName(_ name: String) {
    var identity = creationIdentity
    identity.appName = name
    #expect(throws: AppCreationIdentity.InvalidIdentity.self) { try identity.validate() }
}

@Test func appCreationIdentityRejectsDifferentAppleFields() {
    for app in [creationApp(name: "Other"), creationApp(bundleId: "org.amosystems.clubbundle.Widget"),
                creationApp(sku: "other"), creationApp(sku: nil), creationApp(locale: "en-US")] {
        #expect(throws: AppCreationIdentity.InvalidIdentity.self) {
            try creationIdentity.verify(app: app, versions: [creationVersion()])
        }
    }
    #expect(throws: AppCreationIdentity.InvalidIdentity.self) {
        try creationIdentity.verify(app: creationApp(), versions: [creationVersion(platform: "MAC_OS")])
    }
    #expect(throws: AppCreationIdentity.InvalidIdentity.self) {
        try creationIdentity.verify(app: creationApp(), versions: [])
    }
}

@Test func appCreationIdentityDecodesPublicSKURatherThanPrivateVendorNumber() throws {
    let appJSON = #"{"id":"app-a","attributes":{"bundleId":"org.amosystems.ClubBundle.Widget","name":"Club Bundle","sku":"ClubBundle-iOS","vendorNumber":"old-value","primaryLocale":"de-DE"}}"#
    let versionJSON = #"{"id":"version-a","attributes":{"versionString":"1.0","platform":"IOS"}}"#
    let app = try JSONDecoder().decode(ASCApp.self, from: Data(appJSON.utf8))
    let version = try JSONDecoder().decode(ASCAppStoreVersion.self, from: Data(versionJSON.utf8))
    try creationIdentity.verify(app: app, versions: [version])
}

@MainActor
private final class CreationGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
    func waitForEntry() async { while !entered { await Task.yield() } }
}

@MainActor
private final class CreationServiceMock: ASCAppCreationService {
    var existing: ASCBundleId?
    var registered = ASCBundleId(id: "bundle-a", attributes: .init(identifier: creationIdentity.bundleId, name: "Club Bundle", platform: "IOS"))
    var app = creationApp()
    var versions = [creationVersion()]
    var calls: [String] = []
    var event: ((String) async throws -> Void)?
    private func called(_ name: String) async throws { calls.append(name); try await event?(name) }
    func fetchBundleId(identifier: String) async throws -> ASCBundleId? { try await called("lookup"); return existing }
    func registerBundleId(identifier: String, name: String, platform: String) async throws -> ASCBundleId {
        try await called("register"); return registered
    }
    func enableCapability(bundleIdResourceId: String, capabilityType: String) async throws { try await called("capability") }
    func fetchApp(bundleId: String, exactName: String?) async throws -> ASCApp { try await called("app"); return app }
    func fetchAppStoreVersions(appId: String) async throws -> [ASCAppStoreVersion] { try await called("versions"); return versions }
}

@MainActor
private func creationManager() -> ASCManager {
    let manager = ASCManager()
    manager.loadedProjectId = "project-a"
    manager.credentials = ASCCredentials(issuerId: "test-issuer", keyId: "test-key", privateKey: "unused")
    return manager
}

@MainActor
@Test(arguments: ["lookup", "register", "capability"])
func appCreationRegistrationRejectsProjectSwitchDuringAwait(_ stage: String) async throws {
    let manager = creationManager()
    let service = CreationServiceMock()
    let gate = CreationGate()
    service.event = { if $0 == stage { await gate.pause() } }
    var writes: [String] = []
    let task = Task {
        try await manager.registerBundleIDForCreation(identity: creationIdentity, tab: .app, capabilities: ["ICLOUD"],
            using: service, persist: { project, _ in writes.append(project) })
    }
    await gate.waitForEntry()
    manager.loadedProjectId = "project-b"
    manager.projectRevision = UUID()
    gate.resume()
    do { _ = try await task.value; Issue.record("Stale registration succeeded") } catch {}
    #expect(writes.isEmpty)
    #expect(manager.pendingBundleIDSetup == nil)
    if stage == "lookup" { #expect(service.calls == ["lookup"]) }
    if stage == "register" { #expect(service.calls == ["lookup", "register"]) }
}

@MainActor
@Test func appCreationRegistrationRejectsAccountChange() async {
    let manager = creationManager()
    let service = CreationServiceMock()
    service.event = { _ in manager.credentials?.keyId = "other-account"; await Task.yield() }
    var wrote = false
    do {
        _ = try await manager.registerBundleIDForCreation(identity: creationIdentity, tab: .app, capabilities: [],
            using: service, persist: { _, _ in wrote = true })
        Issue.record("Changed account was accepted")
    } catch {}
    #expect(!wrote)
    #expect(service.calls == ["lookup"])
}

@MainActor
@Test func appCreationRegistrationUsesAppleCanonicalSpellingAndOriginalProject() async throws {
    let manager = creationManager()
    let service = CreationServiceMock()
    let canonical = "org.amosystems.clubbundle.widget"
    service.existing = ASCBundleId(id: "existing-id", attributes: .init(identifier: canonical, name: "Old name", platform: "IOS"))
    var writes: [(String, String)] = []
    let result = try await manager.registerBundleIDForCreation(identity: creationIdentity, tab: .app, capabilities: [],
        using: service, persist: { writes.append(($0, $1)) })
    #expect(service.calls == ["lookup"])
    #expect(result.context.identity.bundleId == canonical)
    #expect(result.context.identity.appName == "Club Bundle")
    #expect(result.context.identity.sku == "ClubBundle-iOS")
    #expect(result.canonicalIdentifierNotice != nil)
    #expect(writes.count == 1)
    #expect(writes.first?.0 == "project-a")
    #expect(writes.first?.1 == canonical)
}

@MainActor
@Test(arguments: [409, 500])
func appCreationRegistrationDoesNotIgnoreCapabilityFailure(_ statusCode: Int) async {
    let manager = creationManager()
    let service = CreationServiceMock()
    service.event = { if $0 == "capability" { throw ASCError.httpError(statusCode, "failed") } }
    var wrote = false
    do {
        _ = try await manager.registerBundleIDForCreation(identity: creationIdentity, tab: .app, capabilities: ["ICLOUD"],
            using: service, persist: { _, _ in wrote = true })
        Issue.record("Capability failure was hidden")
    } catch {}
    #expect(!wrote)
    #expect(manager.pendingBundleIDSetup == nil)
}

@MainActor
@Test func appCreationConfirmationRefusesMissingOrUnregisteredOperation() async throws {
    let manager = creationManager()
    let service = CreationServiceMock()
    do {
        _ = try await manager.confirmBundleIDSetupAppCreated(bundleId: creationIdentity.bundleId, using: service, refreshData: false)
        Issue.record("Confirmation without a registered operation succeeded")
    } catch {}
    _ = try manager.beginPendingBundleIDSetup(identity: creationIdentity, tab: .app)
    do {
        _ = try await manager.confirmBundleIDSetupAppCreated(using: service, refreshData: false)
        Issue.record("Unregistered operation was accepted")
    } catch {}
    #expect(service.calls.isEmpty)
}

@MainActor
@Test func appCreationConfirmationRejectsOverrideAndPreviousOperation() async throws {
    let manager = creationManager()
    let service = CreationServiceMock()
    let old = try await manager.registerBundleIDForCreation(identity: creationIdentity, tab: .app, capabilities: [], using: service, persist: { _, _ in })
    let current = try await manager.registerBundleIDForCreation(identity: creationIdentity, tab: .app, capabilities: [], using: service, persist: { _, _ in })
    service.calls = []
    do {
        _ = try await manager.confirmBundleIDSetupAppCreated(bundleId: "org.example.Other", using: service, refreshData: false)
        Issue.record("Foreign bundle ID accepted")
    } catch {}
    do {
        _ = try await manager.confirmBundleIDSetupAppCreated(operationId: old.context.operationId.uuidString, using: service, refreshData: false)
        Issue.record("Previous operation accepted")
    } catch {}
    do {
        _ = try await manager.confirmBundleIDSetupAppCreated(expectedSKU: "Wrong-SKU", using: service, refreshData: false)
        Issue.record("Unexpected SKU accepted")
    } catch {}
    #expect(service.calls.isEmpty)
    #expect(manager.pendingBundleIDSetup?.operationId == current.context.operationId)
}

@MainActor
@Test(arguments: ["app", "versions"])
func appCreationConfirmationRejectsDelayedResultAfterProjectChange(_ stage: String) async throws {
    let manager = creationManager()
    let service = CreationServiceMock()
    _ = try await manager.registerBundleIDForCreation(identity: creationIdentity, tab: .app, capabilities: [], using: service, persist: { _, _ in })
    let gate = CreationGate()
    service.event = { if $0 == stage { await gate.pause() } }
    let task = Task { try await manager.confirmBundleIDSetupAppCreated(using: service, refreshData: false) }
    await gate.waitForEntry()
    manager.loadedProjectId = "project-b"
    manager.projectRevision = UUID()
    manager.app = creationApp(name: "Other project's app")
    gate.resume()
    do { _ = try await task.value; Issue.record("Stale app was confirmed") } catch {}
    #expect(manager.app?.name == "Other project's app")
}

@MainActor
@Test func appCreationConfirmationVerifiesAllFieldsBeforeAssigningApp() async throws {
    let manager = creationManager()
    let service = CreationServiceMock()
    let result = try await manager.registerBundleIDForCreation(identity: creationIdentity, tab: .app, capabilities: [], using: service, persist: { _, _ in })
    service.app = creationApp(sku: "Wrong-SKU")
    do {
        _ = try await manager.confirmBundleIDSetupAppCreated(using: service, refreshData: false)
        Issue.record("Wrong Apple SKU accepted")
    } catch {}
    #expect(manager.app == nil)
    #expect(manager.pendingBundleIDSetup != nil)
    service.app = creationApp()
    let app = try await manager.confirmBundleIDSetupAppCreated(bundleId: creationIdentity.bundleId,
        expectedName: creationIdentity.appName, expectedSKU: creationIdentity.sku, expectedPlatform: "iOS",
        expectedLocale: "de-DE", projectId: "project-a", operationId: result.context.operationId.uuidString,
        using: service, refreshData: false)
    #expect(app.id == "app-a")
    #expect(manager.app?.id == "app-a")
    #expect(manager.pendingBundleIDSetup == nil)
}
