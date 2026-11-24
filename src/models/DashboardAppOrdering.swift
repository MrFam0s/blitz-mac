import Foundation

enum DashboardAppSortField: String, CaseIterable {
    case name, status, modified
}

enum DashboardAppSortDirection: String, CaseIterable {
    case ascending, descending
}

/// The single status shown by a dashboard card, including stale/unknown data.
enum DashboardAppStatus: Int, CaseIterable {
    case rejected, pendingReview, live, unavailable, draft, localOnly, unknown
}

enum DashboardPlatformGroup: CaseIterable {
    case iOS, macOS, shared, other

    init(platformCodes: [String]?) {
        let codes = Set(platformCodes ?? [])
        if codes == ["IOS"] {
            self = .iOS
        } else if codes == ["MAC_OS"] {
            self = .macOS
        } else if codes.contains("IOS") && codes.contains("MAC_OS") {
            self = .shared
        } else {
            self = .other
        }
    }
}

struct DashboardPlatformSection: Identifiable {
    let id: DashboardPlatformGroup
    let rows: [DashboardAppRow]
}

enum DashboardAppOrdering {
    static func platformSections(for sortedRows: [DashboardAppRow]) -> [DashboardPlatformSection] {
        let groups = Dictionary(grouping: sortedRows) { DashboardPlatformGroup(platformCodes: $0.platformCodes) }
        return DashboardPlatformGroup.allCases.compactMap { group in
            groups[group].map { DashboardPlatformSection(id: group, rows: $0) }
        }
    }

    static func status(for row: DashboardAppRow,
                       unavailableStatusBundleIDs: Set<String> = []) -> DashboardAppStatus {
        if row.source == .localOnly { return .localOnly }
        if let bundleID = row.bundleId, unavailableStatusBundleIDs.contains(bundleID) { return .unknown }
        guard let status = row.status else { return .unknown }
        if status.isRejected { return .rejected }
        if status.isPendingReview { return .pendingReview }
        if status.isLiveOnStore { return .live }
        if status.isUnavailableOnStore { return .unavailable }
        return .draft
    }

    static func sorted(_ rows: [DashboardAppRow], by field: DashboardAppSortField,
                       direction: DashboardAppSortDirection,
                       unavailableStatusBundleIDs: Set<String> = []) -> [DashboardAppRow] {
        rows.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch field {
            case .name:
                comparison = compareNames(lhs.name, rhs.name)
            case .status:
                let left = status(for: lhs, unavailableStatusBundleIDs: unavailableStatusBundleIDs).rawValue
                let right = status(for: rhs, unavailableStatusBundleIDs: unavailableStatusBundleIDs).rawValue
                comparison = left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending
            case .modified:
                switch (lhs.sortDate, rhs.sortDate) {
                case let (.some(left), .some(right)):
                    comparison = left.compare(right)
                // Unknown dates always follow dated apps, in either direction.
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): comparison = .orderedSame
                }
            }
            if comparison != .orderedSame {
                return direction == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
            // Ties keep a predictable alphabetical order even for newest-first
            // dates and reversed status groups.
            let nameComparison = compareNames(lhs.name, rhs.name)
            if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
            let leftIdentity = [lhs.id, lhs.ascAppId ?? "", lhs.source.rawValue]
            let rightIdentity = [rhs.id, rhs.ascAppId ?? "", rhs.source.rawValue]
            return leftIdentity.lexicographicallyPrecedes(rightIdentity)
        }
    }

    private static func compareNames(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.localizedStandardCompare(rhs)
    }
}
