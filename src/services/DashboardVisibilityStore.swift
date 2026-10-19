import Foundation

/// Dashboard preferences only: hiding an app never deletes its project or ASC record.
@MainActor
@Observable
final class DashboardVisibilityStore {
    static let shared = DashboardVisibilityStore()

    private var hiddenApps: [Set<String>]
    private let fileURL: URL

    init(fileURL: URL = BlitzPaths.root.appendingPathComponent("dashboard-hidden-apps.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Set<String>].self, from: data) {
            hiddenApps = saved
        } else {
            hiddenApps = []
        }
    }

    func isHidden(_ row: DashboardAppRow) -> Bool {
        hiddenApps.contains { !$0.isDisjoint(with: row.visibilityKeys) }
    }

    func setHidden(_ hidden: Bool, for row: DashboardAppRow) throws {
        let keys = row.visibilityKeys
        let matching = hiddenApps.filter { !$0.isDisjoint(with: keys) }
        var next = hiddenApps.filter { $0.isDisjoint(with: keys) }
        if hidden {
            next.append(matching.reduce(into: keys) { $0.formUnion($1) })
        }
        // Restore the entire identity group even while its local link is unavailable.
        guard next != hiddenApps else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next.map { $0.sorted() })
        try data.write(to: fileURL, options: .atomic)
        // A failed write must not pretend the preference was saved.
        hiddenApps = next
    }
}

extension DashboardAppRow {
    /// Bundle identity survives refresh, relinking, and local-to-ASC transitions.
    /// Project identity also covers local projects with no bundle ID yet.
    var visibilityKeys: Set<String> {
        var keys: Set<String> = []
        if let bundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleId.isEmpty {
            keys.insert("bundle:\(bundleId)")
        }
        if let ascAppId { keys.insert("asc:\(ascAppId)") }
        if let linkedProjectId { keys.insert("project:\(linkedProjectId)") }
        return keys.isEmpty ? ["row:\(id)"] : keys
    }

    func matches(searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || name.localizedStandardContains(query)
            || (bundleId?.localizedStandardContains(query) ?? false)
    }
}
