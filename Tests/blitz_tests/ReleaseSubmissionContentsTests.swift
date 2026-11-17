import Foundation
import Testing
@testable import Blitz

private func contentTarget() -> ReleaseWorkflowTarget {
    .init(projectID: "project", projectPath: "/tmp", appID: "app1", bundleID: "org.example.App", platform: "IOS",
          accountKey: "issuer:key", versionID: "version1", buildID: "build1", reviewItems: [
            .init(type: .inAppPurchaseVersions, id: "purchase1"),
            .init(type: .subscriptionVersions, id: "subscription1"),
            .init(type: .subscriptionGroupVersions, id: "group1")])
}

private func contentItem(_ name: String, _ type: String, _ id: String, state: String = "READY_FOR_REVIEW") -> [String: Any] {
    ["id": "item-\(id)", "type": "reviewSubmissionItems", "attributes": ["state": state], "relationships": [
        name: ["data": ["id": id, "type": type]],
        "reviewSubmission": ["data": ["id": "draft1", "type": "reviewSubmissions"]]]]
}

private func completeContent() -> [[String: Any]] {
    [contentItem("appStoreVersion", "appStoreVersions", "version1"),
     contentItem("inAppPurchaseVersion", "inAppPurchaseVersions", "purchase1"),
     contentItem("subscriptionVersion", "subscriptionVersions", "subscription1"),
     contentItem("subscriptionGroupVersion", "subscriptionGroupVersions", "group1")]
}

@Test func jointSubmissionRequiresCompleteExactAuthorizedSet() {
    let target = contentTarget(), items = completeContent()
    let complete = ReleaseSubmissionContents(items: items, target: target, submissionID: "draft1")
    #expect(complete.complete && complete.ready && complete.validSelection)
    #expect(complete.appItemID == "item-version1")
    #expect(complete.reviewItemIDs.count == 3)
    for count in 0..<items.count {
        let partial = ReleaseSubmissionContents(items: Array(items.prefix(count)), target: target, submissionID: "draft1")
        #expect(partial.validSelection && partial.ready)
        #expect(!partial.complete)
    }
}

@Test func jointSubmissionRejectsExtraForeignDuplicateOrAmbiguousContent() {
    let original = completeContent()
    var sameID = contentItem("inAppPurchaseVersion", "inAppPurchaseVersions", "purchase1")
    sameID["id"] = "second-item-for-same-product"
    var dual = original[0]
    var relations = dual["relationships"] as! [String: Any]
    relations["inAppPurchaseVersion"] = ["data": ["id": "purchase1", "type": "inAppPurchaseVersions"]]
    dual["relationships"] = relations
    var unknownLink = original[0]
    relations = unknownLink["relationships"] as! [String: Any]
    relations["appEvent"] = ["links": ["related": "/v1/appEvents/unknown"]]
    unknownLink["relationships"] = relations
    let variants = [original + [sameID], original + [original[0]], original + [contentItem("appEvent", "appEvents", "event1")],
                    original + [contentItem("inAppPurchaseVersion", "inAppPurchaseVersions", "foreign-version")],
                    [dual] + Array(original.dropFirst()), [unknownLink] + Array(original.dropFirst()),
                    [contentItem("appStoreVersion", "subscriptions", "version1")] + Array(original.dropFirst())]
    for items in variants {
        let result = ReleaseSubmissionContents(items: items, target: contentTarget(), submissionID: "draft1")
        #expect(!result.validSelection && !result.complete && !result.ready)
    }
    let wrongDraft = ReleaseSubmissionContents(items: original, target: contentTarget(), submissionID: "other-draft")
    #expect(!wrongDraft.validSelection)
}

@Test func jointSubmissionDistinguishesSubmittedExactSetFromResumableDraft() {
    let items = completeContent().map { item -> [String: Any] in
        var result = item; result["attributes"] = ["state": "WAITING_FOR_REVIEW"]; return result
    }
    let result = ReleaseSubmissionContents(items: items, target: contentTarget(), submissionID: "draft1")
    #expect(result.complete && !result.ready)
    let appOnly = ReleaseWorkflowTarget(projectID: "project", projectPath: "/tmp", appID: "app1", bundleID: "org.example.App",
        platform: "IOS", accountKey: "issuer:key", versionID: "version1", buildID: "build1")
    #expect(!ReleaseSubmissionContents(items: items, target: appOnly, submissionID: "draft1").complete)
}


@Test func resubmissionContentsKeepAcceptedItemsButNeverRemovedUnknownOrPartialSelections() {
    var items = completeContent()
    items[1]["attributes"] = ["state": "ACCEPTED"]
    items[2]["attributes"] = ["state": "APPROVED"]
    let ready = ReleaseSubmissionContents(items: items, target: contentTarget(), submissionID: "draft1")
    #expect(ready.canResubmit && !ready.ready && !ready.canResolve)
    items[0]["attributes"] = ["state": "REJECTED"]
    let rejected = ReleaseSubmissionContents(items: items, target: contentTarget(), submissionID: "draft1")
    #expect(!rejected.canResubmit && rejected.canResolve && rejected.rejectedItemIDs == ["item-version1"])
    for state in ["REMOVED", "UNKNOWN", "WAITING_FOR_REVIEW"] {
        items[0]["attributes"] = ["state": state]
        let invalid = ReleaseSubmissionContents(items: items, target: contentTarget(), submissionID: "draft1")
        #expect(!invalid.canResubmit && !invalid.canResolve)
    }
    #expect(!ReleaseSubmissionContents(items: Array(items.dropLast()), target: contentTarget(), submissionID: "draft1").canResolve)
}
