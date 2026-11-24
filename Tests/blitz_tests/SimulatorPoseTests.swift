import Testing
@testable import Blitz

@Test func simulatorPoseTargetsOnlyTheUniqueControlInTheBoundHostGroup() {
    typealias Control = SimulatorPose.Control
    let targetName = "Project iPhone Duo"
    let header = Control(role: "AXStaticText", identifier: nil, description: nil, text: targetName)
    let camera = Control(role: "AXButton", identifier: "camera.viewfinder", description: "Screenshot", text: nil)
    let record = Control(role: "AXButton", identifier: "record.circle", description: "Record", text: nil)
    let open = Control(role: "AXButton", identifier: nil, description: "Open", text: nil)
    let closed = Control(role: "AXButton", identifier: nil, description: "Closed", text: nil)
    let partial = Control(role: "AXButton", identifier: nil, description: "Partially Open", text: nil)
    let controls = [header, camera, record, closed, partial, open]
    #expect(SimulatorPose.open.buttonIndex(in: controls, for: targetName) == 5)
    #expect(SimulatorPose.closed.buttonIndex(in: controls, for: targetName) == 3)
    #expect(SimulatorPose.partiallyOpen.buttonIndex(in: controls, for: targetName) == 4)
    #expect(SimulatorPose.open.buttonIndex(in: controls, for: "Another Project") == nil)
    #expect(SimulatorPose.open.buttonIndex(in: [header, open], for: targetName) == nil)
    #expect(SimulatorPose.open.buttonIndex(in: controls + [open], for: targetName) == nil)
}

@Test func simulatorPoseMCPRequiresExplicitDeviceAndProjectApproval() throws {
    let tool = try #require(MCPRegistry.allTools().first { $0["name"] as? String == "simulator_set_pose" })
    let schema = try #require(tool["inputSchema"] as? [String: Any])
    #expect(schema["required"] as? [String] == ["projectId", "udid", "pose"])
    #expect(MCPRegistry.category(for: "simulator_set_pose") == .simulatorControl)
}

@Suite struct SimulatorPoseRoutingTests {
    let udid = "BE4AA350-E188-4130-805D-EE27F7FAE524"
    let old = "/old/axe"
    let current = "/new/axe"
    let genericHelp = #"{"command":"axe","didError":false,"data":{"messages":["USAGE: axe <subcommand>"]}}"#
    let supportedHelp = #"{"command":"axe","didError":false,"data":{"messages":["OVERVIEW: Set a hinge.\n\nUSAGE: axe hinge set <degrees> --udid <udid>"]}}"#

    private func device(_ id: String, state: String = "Booted", type: String = SimulatorPose.deviceType) -> SimctlClient.SimctlDevice {
        .init(udid: id, name: "Shared name", state: state, isAvailable: true, deviceTypeIdentifier: type, lastBootedAt: nil)
    }

    private func result(id: String, degrees: Double, posture: String, role: String, mechanical: Double? = nil) -> String {
        #"{"command":"hinge set","didError":false,"data":{"result":{"udid":"\#(id)","hinge":{"degrees":\#(degrees),"mechanicalDegrees":\#(mechanical ?? degrees),"posture":"\#(posture)"},"activeScreen":{"role":"\#(role)"}}}}"#
    }

    @MainActor @Test(arguments: SimulatorPose.allCases)
    func appliesOnceByUDIDEvenWithDuplicateNames(_ pose: SimulatorPose) async throws {
        var calls: [[String]] = []
        let angle: Double = pose == .closed ? 0 : pose == .open ? 180 : 86.5
        let role = pose == .closed ? "outer" : "inner"
        let axe = AXeSimulator(candidates: [old, current]) { path, args in
            calls.append([path] + args)
            if args.last == "--help" { return path == old ? genericHelp : supportedHelp }
            return result(id: udid.lowercased(), degrees: angle, posture: pose.rawValue, role: role, mechanical: pose == .partiallyOpen ? 90 : angle)
        }
        let outcome = try await pose.apply(udid: udid, devices: [device("other"), device(udid)], isBound: { true }, axe: axe) { _ in
            Issue.record("AXe should address the device without Device Hub")
        }
        let probe = ["--output", "json", "hinge", "set", "--help"]
        #expect(calls == [[old] + probe, [current] + probe, [current, "--output", "json", "hinge", "set", pose == .partiallyOpen ? "tabletop" : pose.rawValue, "--udid", udid]])
        #expect(outcome == .confirmed(degrees: angle, activeDisplay: role))
        #expect(outcome.mcpFields["confirmed"] as? Bool == true)
    }

    @MainActor @Test func olderOrAbsentAXeUsesOnlyTheExistingDeviceHubRoute() async throws {
        for paths in [[], [old]] {
            var requests: [String] = []
            let axe = AXeSimulator(candidates: paths) { _, args in
                #expect(args.last == "--help")
                return genericHelp
            }
            let outcome = try await SimulatorPose.open.apply(udid: udid, devices: [device(udid)], isBound: { true }, axe: axe) { requests.append($0) }
            #expect(requests == ["Shared name"])
            #expect(outcome == .requestedInDeviceHub)
            #expect(outcome.mcpFields["confirmed"] as? Bool == false)
            await #expect(throws: SimulatorCaptureService.CaptureError.self) {
                try await SimulatorPose.open.apply(udid: udid, devices: [device(udid), device("duplicate")], isBound: { true }, axe: axe) { _ in
                    Issue.record("Ambiguous windows must not receive a request")
                }
            }
        }
    }

    @MainActor @Test func refusesInvalidOrChangedDeviceBeforeAnyWrite() async {
        for inventory in [[device("other")], [device(udid, state: "Shutdown")], [device(udid, type: "iPad")], [device(udid)]] {
            var bound = true
            let axe = AXeSimulator(candidates: [current]) { _, args in
                #expect(inventory.first?.deviceTypeIdentifier == SimulatorPose.deviceType && inventory.first?.isBooted == true && inventory.first?.udid == udid)
                #expect(args.last == "--help")
                bound = false
                return supportedHelp
            }
            await #expect(throws: SimulatorPose.PoseError.self) {
                try await SimulatorPose.open.apply(udid: udid, devices: inventory, isBound: { bound }, axe: axe) { _ in
                    Issue.record("Project or device changed")
                }
            }
        }
    }

    @MainActor @Test func failedOrUnconfirmedMoveNeverFallsBackOrRetries() async {
        let replies: [String?] = [
            nil, "invalid JSON",
            result(id: "different", degrees: 180, posture: "open", role: "inner"),
            result(id: udid, degrees: 0, posture: "closed", role: "outer"),
            result(id: udid, degrees: 180, posture: "open", role: "main"),
            result(id: udid, degrees: 180, posture: "open", role: "inner", mechanical: 90)
        ]
        for reply in replies {
            var moves = 0
            let axe = AXeSimulator(candidates: [current]) { _, args in
                if args.last == "--help" { return supportedHelp }
                moves += 1
                guard let reply else { throw ProcessRunner.ProcessError(command: "hinge set", exitCode: 1, stderr: "bootChanged") }
                return reply
            }
            await #expect(throws: Error.self) {
                try await SimulatorPose.open.apply(udid: udid, devices: [device(udid)], isBound: { true }, axe: axe) { _ in
                    Issue.record("Must never issue a second move")
                }
            }
            #expect(moves == 1)
        }
    }
}
