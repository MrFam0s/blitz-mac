import Foundation
import Testing
@testable import Blitz

@MainActor
@Test func dashboardHiddenAppSurvivesRestartRefreshAndRelinking() throws {
    let file = dashboardVisibilityTestURL()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let local = dashboardVisibilityRow(source: .localOnly, project: "imported")
    let writer = DashboardVisibilityStore(fileURL: file)
    try writer.setHidden(true, for: local)

    let restarted = DashboardVisibilityStore(fileURL: file)
    let refreshed = dashboardVisibilityRow(source: .asc, project: "imported", name: "Renamed App")
    #expect(restarted.isHidden(refreshed))
    #expect(!restarted.isHidden(dashboardVisibilityRow(bundle: "org.example.other", project: "other")))

    // Restore while the ASC row has not yet been linked to its local project.
    try restarted.setHidden(false, for: dashboardVisibilityRow(source: .asc, project: nil))
    #expect(!restarted.isHidden(local))
    #expect(!DashboardVisibilityStore(fileURL: file).isHidden(refreshed))
}

@MainActor
@Test func dashboardHidingDoesNotModifyProjectFiles() throws {
    let file = dashboardVisibilityTestURL()
    let directory = file.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let projectDirectory = directory.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
    let source = projectDirectory.appendingPathComponent("App.swift")
    let code = "// Keep this source file unchanged.\n"
    try code.write(to: source, atomically: true, encoding: .utf8)
    let project = Project(id: "source", metadata: BlitzProjectMetadata(name: "Local App", type: .swift), path: projectDirectory.path)
    let row = DashboardAppRow.localOnly(project: project)
    let store = DashboardVisibilityStore(fileURL: file)
    try store.setHidden(true, for: row)
    #expect(store.isHidden(row))
    #expect(try String(contentsOf: source, encoding: .utf8) == code)
    try store.setHidden(false, for: row)
    #expect(!DashboardVisibilityStore(fileURL: file).isHidden(row))
}

@MainActor
@Test func dashboardFailedPreferenceWriteDoesNotHideTheApp() throws {
    let file = dashboardVisibilityTestURL()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    // A directory at the file path reliably makes atomic file replacement fail.
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    let store = DashboardVisibilityStore(fileURL: file)
    let row = dashboardVisibilityRow()
    #expect(throws: (any Error).self) { try store.setHidden(true, for: row) }
    #expect(!store.isHidden(row))
}

@MainActor
@Test func dashboardRestoreKeepsOtherHiddenApps() throws {
    let file = dashboardVisibilityTestURL()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = DashboardVisibilityStore(fileURL: file)
    let first = dashboardVisibilityRow()
    let second = dashboardVisibilityRow(bundle: "org.example.second", project: "second")
    try store.setHidden(true, for: first)
    try store.setHidden(true, for: first)
    try store.setHidden(true, for: second)
    try store.setHidden(false, for: first)
    let restored = DashboardVisibilityStore(fileURL: file)
    #expect(!restored.isHidden(first))
    #expect(restored.isHidden(second))
}

@Test func dashboardSearchFindsNamesAndBundleIDs() {
    let row = dashboardVisibilityRow(name: "Mühlenstein")
    #expect(row.matches(searchText: "  MÜHLEN  "))
    #expect(row.matches(searchText: "EXAMPLE.APP"))
    #expect(row.matches(searchText: " \n"))
    #expect(!row.matches(searchText: "another app"))
}

private func dashboardVisibilityTestURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("hidden.json")
}

private func dashboardVisibilityRow(
    bundle: String = "org.example.app",
    source: DashboardAppRow.Source = .localOnly,
    project: String? = "project",
    name: String = "Example App"
) -> DashboardAppRow {
    DashboardAppRow(id: bundle, bundleId: bundle, name: name, source: source,
                    ascAppId: source == .asc ? "asc-\(bundle)" : nil,
                    linkedProjectId: project, status: nil, iconURL: nil)
}
