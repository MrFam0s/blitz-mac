import Foundation
import Testing
@testable import Blitz

@Suite struct AXeSimulatorScreenshotTests {
    enum Scenario: CaseIterable { case stable, wrongBoot, wrongPanel, rotated, wrongPixels, resizedPNG, captureFailed }
    let udid = "be4aa350-e188-4130-805d-ee27f7fae524"
    let screen = "73CFD4D2-A0D2-4CB5-A911-F613A13217C7"
    let boot = "234:567:890"
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAYAAAADCAIAAAA/Y+msAAAAEUlEQVR4nGNgZGJGQwxECQEADBsAbQyklcYAAAAASUVORK5CYII=")!

    @Test func captureRequiresPanelAndBootSupportBeforeChoosingAXe() async {
        let paths = ["/unrelated/axe", "/old/axe", "/current/axe"]
        var probed: [String] = []
        let axe = AXeSimulator(candidates: paths) { path, args in
            #expect(args == ["--output", "json", "screenshot", "--help-hidden"])
            probed.append(path)
            let usage: String
            switch path {
            case paths[0]: usage = "USAGE: axe <command>"
            case paths[1]: usage = "USAGE: axe screenshot --udid <udid> [--screen-id ID] [--screen-uuid UUID] [--verbose]"
            default: usage = "USAGE: axe screenshot --udid <udid> [--screen-id ID] [--screen-uuid UUID] [--expected-boot BOOT] [--verbose]"
            }
            return #"{"command":"axe","didError":false,"data":{"messages":["\#(usage)"]}}"#
        }
        #expect(await axe.supportedScreenshotExecutable() == paths[2])
        #expect(probed == paths)
        let legacy = AXeSimulator(candidates: [paths[1]], run: axe.run)
        #expect(await legacy.supportedScreenshotExecutable() == nil)
    }

    @Test(arguments: Scenario.allCases)
    func captureIsPinnedToPanelAndBootAndPreservesOriginalPNG(_ scenario: Scenario) async throws {
        var captureFile: URL?
        var captureCount = 0
        let axe = AXeSimulator(candidates: ["/test/axe"]) { _, arguments in
            func response(_ command: String, _ result: [String: Any]) throws -> String {
                let envelope: [String: Any] = ["command": command, "didError": false, "data": ["result": result]]
                return String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
            }
            if arguments == ["--output", "json", "displays", "--udid", udid] {
                return try response("displays", ["udid": udid.uppercased(), "activeScreen": ["id": 38, "uuid": screen,
                    "role": "inner", "width": scenario == .resizedPNG ? 3 : 2, "height": 1, "scale": 3, "rotation": 90]])
            }
            if arguments == ["--output", "json", "displays", "--udid", udid, "--verbose"] {
                return try response("displays", ["requestedSimulatorUDID": udid.uppercased(), "bootIdentity": boot,
                    "activePanel": ["identity": ["displayID": 38, "uniqueID": screen]]])
            }
            captureCount += 1
            guard let output = arguments.dropFirst(2).firstIndex(of: "--output"), arguments.indices.contains(output + 1)
            else { throw SimulatorScreen.ScreenError.ambiguous }
            let file = URL(fileURLWithPath: arguments[output + 1])
            captureFile = file
            #expect(arguments == ["--output", "json", "screenshot", "--udid", udid, "--screen-id", "38",
                                  "--screen-uuid", screen, "--expected-boot", boot, "--output", file.path, "--verbose"])
            try png.write(to: file)
            if scenario == .captureFailed {
                let stderr = #"{"command":"screenshot","didError":true,"error":{"code":"timeout","message":"Display did not settle"},"data":{"messages":["diagnostic details"]}}"#
                throw ProcessRunner.ProcessError(command: "axe screenshot", exitCode: 1, stderr: stderr)
            }
            let before: [String: Any] = ["simulatorUDID": udid.uppercased(), "screenID": 38, "screenUniqueID": screen,
                "bootIdentity": boot, "rotation": 90, "scale": 3, "poseRevision": "mechanicalDegrees=90.0"]
            var after = before
            if scenario == .wrongBoot { after["bootIdentity"] = "345:678:901" }
            if scenario == .wrongPanel { after["screenID"] = 1 }
            if scenario == .rotated { after["rotation"] = 270 }
            return try response("screenshot", ["before": ["observation": before], "after": ["observation": after],
                                               "width": scenario == .resizedPNG ? 9 : 6, "height": scenario == .wrongPixels ? 6 : 3])
        }
        if scenario == .stable {
            #expect(try await axe.captureActiveDuoPNG(udid: udid, using: "/test/axe") == png)
        } else if scenario == .captureFailed {
            await #expect {
                try await axe.captureActiveDuoPNG(udid: udid, using: "/test/axe")
            } throws: { error in
                error.localizedDescription == "AXe (timeout): Display did not settle"
            }
        } else {
            await #expect(throws: Error.self) { try await axe.captureActiveDuoPNG(udid: udid, using: "/test/axe") }
        }
        #expect(captureCount == 1)
        let staged = try #require(captureFile)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }
}
