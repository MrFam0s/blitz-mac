import Foundation
import Testing
@testable import Blitz

@MainActor @Test func terminalLayoutKeepsIndependentSizesAcrossRelaunch() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("settings.json")
    let settings = SettingsService(settingsURL: url)
    settings.terminalPosition = "right"
    settings.terminalRightWidth = 532
    settings.terminalBottomHeight = 273
    settings.save()

    let restored = SettingsService(settingsURL: url)
    #expect(restored.terminalPosition == "right")
    #expect(restored.terminalRightWidth == 532)
    #expect(restored.terminalBottomHeight == 273)
    restored.terminalPosition = "bottom"
    restored.save()
    let switched = SettingsService(settingsURL: url)
    #expect(switched.terminalRightWidth == 532)
    #expect(switched.terminalBottomHeight == 273)
}

@MainActor @Test func terminalLayoutMigratesOldSettingsAndRejectsInvalidSizes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("settings.json")
    try Data(#"{"terminalPosition":"right","autoNavEnabled":false}"#.utf8).write(to: url)
    let settings = SettingsService(settingsURL: url)
    #expect(settings.terminalRightWidth == 480)
    #expect(settings.terminalBottomHeight == 250)
    #expect(!settings.autoNavEnabled)
    try Data(#"{"terminalRightWidth":-1,"terminalBottomHeight":"oops"}"#.utf8).write(to: url)
    settings.load()
    #expect(settings.terminalRightWidth == 480)
    #expect(settings.terminalBottomHeight == 250)
}
