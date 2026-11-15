import Foundation

/// Read the complete content set of a review draft. A matching app item alone
/// never authorizes other products (or events) added by another client.
struct ReleaseSubmissionContents {
    let appItemID: String?
    let reviewItemIDs: [String: String]
    let validSelection: Bool
    let complete: Bool
    let ready: Bool
    let referencesAppVersion: Bool

    init(items: [[String: Any]], target: ReleaseWorkflowTarget, submissionID: String) {
        let appKey = "appStoreVersions:\(target.versionID)"
        let expected = Set([appKey] + target.reviewItems.map(\.key))
        let relations = ["appStoreVersion": "appStoreVersions", "inAppPurchaseVersion": "inAppPurchaseVersions",
                         "subscriptionVersion": "subscriptionVersions", "subscriptionGroupVersion": "subscriptionGroupVersions"]
        var found: [String: String] = [:]
        var itemIDs: Set<String> = []
        var valid = true, allReady = true, referencesVersion = false
        for item in items {
            guard let id = item["id"] as? String, ReleaseWorkflowTarget.validID(id),
                  itemIDs.insert(id).inserted,
                  let relationships = item["relationships"] as? [String: [String: Any]] else {
                valid = false; continue
            }
            if let app = relationships["appStoreVersion"]?["data"] as? [String: Any],
               app["id"] as? String == target.versionID { referencesVersion = true }
            var keys: [String] = []
            for (name, relationship) in relationships {
                if relationship["data"] is NSNull { continue }
                guard let data = relationship["data"] as? [String: Any],
                      let relatedID = data["id"] as? String, ReleaseWorkflowTarget.validID(relatedID),
                      let type = data["type"] as? String else { valid = false; continue }
                if name == "reviewSubmission" {
                    if type != "reviewSubmissions" || relatedID != submissionID { valid = false }
                    continue
                }
                guard relations[name] == type else { valid = false; continue }
                keys.append("\(type):\(relatedID)")
            }
            guard keys.count == 1, let key = keys.first, expected.contains(key), found[key] == nil else {
                valid = false; continue
            }
            found[key] = id
            if (item["attributes"] as? [String: Any])?["state"] as? String != "READY_FOR_REVIEW" { allReady = false }
        }
        appItemID = found[appKey]
        reviewItemIDs = found.filter { $0.key != appKey }
        validSelection = valid
        complete = valid && Set(found.keys) == expected
        ready = valid && allReady
        referencesAppVersion = referencesVersion
    }
}
