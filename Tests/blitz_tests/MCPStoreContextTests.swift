import Foundation
import Testing
@testable import Blitz

struct MCPStoreContextTests {
    let target = ["projectId": "Project", "appId": "12", "bundleId": "org.example.Test", "platform": "IOS"]

    @Test func exactlyOneNamedTargetAndAccount() throws {
        let name = "store_availability_get"
        let op = UUID().uuidString
        try MCPStoreArguments.validate(name, ["target": target, "accountKey": "a"])
        try MCPStoreArguments.validate(name, ["operationId": op, "accountKey": "a"])
        for bad: [String: Any] in [
            ["target": target], ["accountKey": "a"],
            ["target": target, "accountKey": "a", "operationId": op],
            ["operationId": "../other", "accountKey": "a"],
            ["target": target.merging(["appId": "../other"]) { _, new in new }, "accountKey": "a"],
            ["target": target.merging(["projectPath": "/tmp"]) { _, new in new }, "accountKey": "a"],
            ["target": target, "accountKey": "a", "arguments": ["--force"]]
        ] {
            #expect(throws: (any Error).self) { try MCPStoreArguments.validate(name, bad) }
        }
    }

    @Test func previewRequiresVersionAndWritesRequireBooleanConsent() throws {
        var args: [String: Any] = ["target": target, "accountKey": "a", "locale": "de-DE", "deviceType": "IPHONE_69"]
        #expect(throws: (any Error).self) { try MCPStoreArguments.validate("store_previews_list", args) }
        args["target"] = target.merging(["versionId": "v1"]) { _, new in new }
        try MCPStoreArguments.validate("store_previews_list", args)
        args["filePath"] = "de.mp4"
        for invalid: Any? in [nil, false, 1, "true"] {
            args["confirm"] = invalid
            #expect(throws: (any Error).self) { try MCPStoreArguments.validate("store_preview_upload", args) }
        }
        args["confirm"] = true
        try MCPStoreArguments.validate("store_preview_upload", args)
    }

    @Test func newWritesHaveScopedApprovalCategories() {
        let names = MCPRegistry.storeTools.compactMap { $0["name"] as? String }
        #expect(Set(names).count == 7)
        for name in names {
            #expect(MCPRegistry.allToolNames().filter { $0 == name }.count == 1)
            let category = MCPRegistry.category(for: name)
            if name.hasSuffix("_get") || name.hasSuffix("_list") { #expect(category == .query) }
            else if name.hasPrefix("store_preview") { #expect(category == .ascPreviewMutation) }
            else if name.hasPrefix("store_china") { #expect(category == .ascComplianceMutation) }
            else { #expect(category == .ascAvailabilityMutation) }
            if category != .query {
                let request = ApprovalRequest(id: "test", toolName: name, description: "", parameters: [:], category: category)
                #expect(request.requiresApproval(permissionToggles: ["ascScreenshotMutation": true, "ascFormMutation": true]))
                #expect(!request.requiresApproval(permissionToggles: [category.rawValue: true]))
            }
        }
    }

    @Test func stagedFilesAreConfinedAndStable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let original = root.appendingPathComponent("Video DE.mp4")
        try Data("first".utf8).write(to: original)
        try fm.createSymbolicLink(at: root.appendingPathComponent("linked.mp4"), withDestinationURL: original)
        try fm.createSymbolicLink(at: root.appendingPathComponent("folder"), withDestinationURL: root)
        let staged = try MCPStoreFile.stage(relativePath: original.lastPathComponent, projectRoot: root, allowedExtensions: ["mp4"])
        defer { staged.remove() }
        try Data("second".utf8).write(to: original)
        #expect(staged.url.lastPathComponent == original.lastPathComponent)
        #expect(try Data(contentsOf: staged.url) == Data("first".utf8))
        for path in ["../Video DE.mp4", original.path, "linked.mp4", "folder/Video DE.mp4", ".git/a.mp4", "a.mov"] {
            #expect(throws: (any Error).self) { try MCPStoreFile.stage(relativePath: path, projectRoot: root, allowedExtensions: ["mp4"]) }
        }
        #expect(throws: (any Error).self) {
            try MCPStoreFile.stage(relativePath: original.lastPathComponent, projectRoot: root, allowedExtensions: ["mp4"], maxBytes: 2)
        }
    }
}
