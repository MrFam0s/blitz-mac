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
