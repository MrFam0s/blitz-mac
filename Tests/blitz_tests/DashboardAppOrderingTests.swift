import Foundation
import Testing
@testable import Blitz

@Test func dashboardNameOrderingIncludesLocalAppsAndUsesNaturalNames() {
    let rows = [orderingRow("z", "Zebra"), orderingRow("10", "App 10"),
                orderingRow("2", "App 2", source: .localOnly), orderingRow("a", "Alpha")]
    #expect(DashboardAppOrdering.sorted(rows, by: .name, direction: .ascending).map(\.id) == ["a", "2", "10", "z"])
    #expect(DashboardAppOrdering.sorted(rows, by: .name, direction: .descending).map(\.id) == ["z", "10", "2", "a"])
    let ties = [orderingRow("b", "Same"), orderingRow("a", "Same")]
    #expect(DashboardAppOrdering.sorted(ties, by: .name, direction: .descending).map(\.id) == ["a", "b"])
}

@Test func dashboardStatusOrderingMatchesTheVisibleBadgeAndStaleData() {
    let live = ASCDashboardProjectStatus(isLiveOnStore: true, isPendingReview: false, isRejected: false)
    let pending = ASCDashboardProjectStatus(isLiveOnStore: true, isPendingReview: true, isRejected: false)
    let rejected = ASCDashboardProjectStatus(isLiveOnStore: true, isPendingReview: true, isRejected: true)
    let removed = ASCDashboardProjectStatus(isLiveOnStore: true, isPendingReview: false, isRejected: false,
                                           storeAvailability: .unavailable)
    let rows = [orderingRow("local", "Local", source: .localOnly), orderingRow("draft", "Draft", status: .empty),
                orderingRow("live", "Live", status: live), orderingRow("pending", "Pending", status: pending),
                orderingRow("rejected", "Rejected", status: rejected), orderingRow("removed", "Removed", status: removed),
                orderingRow("stale", "Stale", status: live), orderingRow("missing", "Missing")]
    let unavailable: Set<String> = ["stale"]
    #expect(DashboardAppOrdering.sorted(rows, by: .status, direction: .ascending,
                                       unavailableStatusBundleIDs: unavailable).map(\.id)
        == ["rejected", "pending", "live", "removed", "draft", "local", "missing", "stale"])
    #expect(DashboardAppOrdering.status(for: rows[3]) == .pendingReview)
    #expect(DashboardAppOrdering.status(for: rows[4]) == .rejected)
    #expect(DashboardAppOrdering.status(for: rows[5]) == .unavailable)
    #expect(DashboardAppOrdering.status(for: rows[6], unavailableStatusBundleIDs: unavailable) == .unknown)
    #expect(DashboardAppOrdering.status(for: rows[0], unavailableStatusBundleIDs: ["local"]) == .localOnly)
}

@Test func dashboardDateOrderingKeepsMissingDatesLastAndUsesObservedChangeFirst() {
    var old = orderingRow("old", "Old")
    old.latestVersionCreatedAt = Date(timeIntervalSince1970: 10)
    var changed = orderingRow("changed", "Changed")
    changed.latestVersionCreatedAt = Date(timeIntervalSince1970: 5)
    changed.lastChangedAt = Date(timeIntervalSince1970: 20)
    let missing = orderingRow("missing", "A Missing Date", source: .localOnly)
    let rows = [missing, changed, old]
    #expect(DashboardAppOrdering.sorted(rows, by: .modified, direction: .ascending).map(\.id) == ["old", "changed", "missing"])
    #expect(DashboardAppOrdering.sorted(rows, by: .modified, direction: .descending).map(\.id) == ["changed", "old", "missing"])
}

@Test func dashboardShowsAvailabilityAfterReviewStatusOnlyWithCurrentEvidence() {
    for rejected in [false, true] {
        let status = ASCDashboardProjectStatus(isLiveOnStore: false, isPendingReview: !rejected,
                                               isRejected: rejected, storeAvailability: .unavailable)
        let row = orderingRow("off-sale", "App", status: status)
        let primary = DashboardAppOrdering.status(for: row)
        #expect(row.dashboardStatuses(primary: primary) == [rejected ? .rejected : .pendingReview, .unavailable])

        let stale = DashboardAppOrdering.status(for: row, unavailableStatusBundleIDs: ["off-sale"])
        #expect(row.dashboardStatuses(primary: stale) == [.unknown])
    }
}

@Test func dashboardRowsDecodeWithoutNewEvidenceFields() throws {
    let row = try JSONDecoder().decode(DashboardAppRow.self, from: Data("""
    {"id":"legacy","bundleId":"org.example.legacy","name":"Legacy","source":"asc","ascAppId":"1"}
    """.utf8))
    #expect(row.platformCodes == nil)
    #expect(row.sortDate == nil)
    #expect(row.latestVersionCreatedAt == nil)
    #expect(row.lastChangedAt == nil)
}

@Test func dashboardPlatformGroupingUsesOnlyProvenPlatformCodes() {
    #expect(DashboardPlatformGroup(platformCodes: ["IOS", "IOS"]) == .iOS)
    #expect(DashboardPlatformGroup(platformCodes: ["MAC_OS"]) == .macOS)
    for extraCodes in [[], ["VISION_OS"], ["UNKNOWN"]] {
        #expect(DashboardPlatformGroup(platformCodes: ["MAC_OS", "IOS"] + extraCodes) == .shared)
    }
    let otherPlatforms: [[String]?] = [nil, [], ["UNKNOWN"], ["TV_OS"], ["FUTURE_PLATFORM"],
                                       ["IOS", "UNKNOWN"], ["MAC_OS", "TV_OS"]]
    for codes in otherPlatforms {
        #expect(DashboardPlatformGroup(platformCodes: codes) == .other)
    }
}

@Test func dashboardPlatformSectionsPreserveTheFilteredSortAndEachAppIdentity() {
    let input = [
        orderingRow("mac-local", "Alpha", source: .localOnly, platforms: ["MAC_OS"]),
        orderingRow("shared", "Same name", platforms: ["MAC_OS", "IOS"]),
        orderingRow("ios-two", "Zulu", platforms: ["IOS"]),
        orderingRow("mac", "Same name", platforms: ["MAC_OS"]),
        orderingRow("other", "Other", platforms: nil),
        orderingRow("ios", "Same name", platforms: ["IOS"])
    ]
    for field in DashboardAppSortField.allCases {
        for direction in DashboardAppSortDirection.allCases {
            let sorted = DashboardAppOrdering.sorted(input, by: field, direction: direction)
            let sections = DashboardAppOrdering.platformSections(for: sorted)
            #expect(sections.map(\.id) == [.iOS, .macOS, .shared, .other])
            #expect(sections.flatMap(\.rows).count == input.count)
            for section in sections {
                let expected = sorted.filter { DashboardPlatformGroup(platformCodes: $0.platformCodes) == section.id }
                #expect(section.rows == expected)
            }
        }
    }
    let filtered = DashboardAppOrdering.platformSections(for: input.filter { $0.name == "Alpha" })
    #expect(filtered.map(\.id) == [.macOS])
    #expect(filtered.flatMap(\.rows).map(\.id) == ["mac-local"])
    #expect(DashboardAppOrdering.platformSections(for: []).isEmpty)
}

private func orderingRow(_ id: String, _ name: String, source: DashboardAppRow.Source = .asc,
                         status: ASCDashboardProjectStatus? = nil, platforms: [String]? = nil) -> DashboardAppRow {
    DashboardAppRow(id: id, bundleId: id, name: name, source: source,
                    ascAppId: source == .asc ? id : nil, linkedProjectId: nil, status: status, iconURL: nil,
                    platformCodes: platforms)
}
