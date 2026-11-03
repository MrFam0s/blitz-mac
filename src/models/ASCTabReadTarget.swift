import Foundation

/// Identity for a read or form save; does not retain credentials or tester data.
struct ASCTabReadTarget: Equatable {
    let revision: UUID
    let projectID: String?
    let appID: String?
    let accountKey: String?
    let credentialRevision: Int

    @MainActor init(_ manager: ASCManager) {
        revision = manager.projectRevision
        projectID = manager.loadedProjectId
        appID = manager.app?.id
        accountKey = DashboardSummaryStore.accountKey(for: manager.credentials)
        credentialRevision = manager.credentialActivationRevision
    }

    @MainActor func matches(_ manager: ASCManager) -> Bool {
        !Task.isCancelled && self == Self(manager)
    }
}

/// A missing key means unchanged; an included empty string means clear the field.
struct ASCBetaInfoChanges {
    static let keys = ["description", "feedbackEmail", "marketingUrl", "privacyPolicyUrl"]

    static func fields(original: [String], edited: [String]) -> [String: String] {
        guard original.count == keys.count, edited.count == keys.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: keys.indices.compactMap { index in
            original[index] == edited[index] ? nil : (keys[index], edited[index])
        })
    }
}
