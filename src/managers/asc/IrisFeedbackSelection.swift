// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation

/// App-wide communication must remain visible even when Apple supplies no
/// version relationship. It is never evidence against an arbitrary version.
struct IrisFeedbackSelection {
    let matched: [IrisFeedbackCycle]
    let unassigned: [IrisFeedbackCycle]

    init(cycles: [IrisFeedbackCycle], version: ASCAppStoreVersion?, knownVersions: [ASCAppStoreVersion]) {
        var matched: [IrisFeedbackCycle] = []
        var unassigned: [IrisFeedbackCycle] = []
        for cycle in cycles {
            let ids = Self.versionIDs(for: cycle, knownVersions: knownVersions)
            if ids.isEmpty {
                unassigned.append(cycle)
            } else if let version, ids.contains(version.id) {
                matched.append(cycle)
            }
        }
        self.matched = matched
        self.unassigned = unassigned
    }

    static func versionIDs(for cycle: IrisFeedbackCycle, knownVersions: [ASCAppStoreVersion]) -> Set<String> {
        let ids = Set((cycle.appStoreVersionIDs ?? []).map(trimmed).filter { !$0.isEmpty })
        if !ids.isEmpty { return ids }
        let label = trimmed(cycle.versionString)
        guard !label.isEmpty else { return [] }
        // Old archives may only contain a text marker. Identical iOS/macOS
        // version numbers are not interchangeable resource identities.
        let candidates = Set(knownVersions.filter { trimmed($0.attributes.versionString) == label }.map(\.id))
        return candidates.count == 1 ? candidates : []
    }

    var hasMessages: Bool { !matched.isEmpty || !unassigned.isEmpty }

    static func payload(_ cycles: [IrisFeedbackCycle]) -> [[String: Any]] {
        cycles.map { cycle in
            [
                "id": cycle.id,
                "version": cycle.versionString as Any? ?? NSNull(),
                "appStoreVersionIds": cycle.appStoreVersionIDs ?? [],
                "submissionId": cycle.submissionId as Any? ?? NSNull(),
                "occurredAt": cycle.occurredAt,
                "source": cycle.source,
                "reasons": cycle.reasons.map { ["section": $0.section, "description": $0.description, "code": $0.code] },
                "messages": cycle.messages.map { message -> [String: Any] in
                    ["id": message.id, "body": message.body,
                     "date": message.createdAt as Any? ?? NSNull(),
                     "sender": message.sender?.rawValue ?? "unknown"]
                }
            ]
        }
    }
}
