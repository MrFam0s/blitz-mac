import Foundation
import Testing
@testable import Blitz

@Test func initialWindowFitsAvailableDisplayWithoutGrowingOnLargeDisplays() {
    #expect(MainWindowLayout.initialFrameSize(visibleSize: CGSize(width: 1728, height: 1080))
            == CGSize(width: 1230, height: 925))
    #expect(MainWindowLayout.initialFrameSize(visibleSize: CGSize(width: 1024, height: 740))
            == CGSize(width: 1024, height: 740))
}

@MainActor @Test func newSettingsUseSideBySideLayoutAndPreserveSavedChoice() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("settings.json")
    let settings = SettingsService(settingsURL: url)
    #expect(settings.terminalPosition == "right")
    #expect(settings.terminalRightWidth == 480)
    settings.terminalPosition = "bottom"
    settings.terminalRightWidth = 560
    settings.save()

    let restored = SettingsService(settingsURL: url)
    #expect(restored.terminalPosition == "bottom")
    #expect(restored.terminalRightWidth == 560)
}

@MainActor @Test func legacySettingsWithoutTerminalPositionUseRightSide() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("settings.json")
    try Data(#"{"hasCompletedOnboarding":true,"terminalRightWidth":525}"#.utf8).write(to: url)
    let settings = SettingsService(settingsURL: url)
    #expect(settings.terminalPosition == "right")
    #expect(settings.terminalRightWidth == 525)
}
