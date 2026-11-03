import Foundation
import Testing
@testable import Blitz

private struct BundleIDTransactionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlitzIDTransaction-\(UUID().uuidString)")
    var file: URL { root.appendingPathComponent("Example.xcodeproj/project.pbxproj") }
    init() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        { objects = {
            APP = { isa = PBXNativeTarget; name = Example; productType = "com.apple.product-type.application"; buildConfigurationList = CONFIGS; };
            CONFIGS = { isa = XCConfigurationList; buildConfigurations = ( RELEASE, ); };
            RELEASE = { isa = XCBuildConfiguration; name = Release; buildSettings = { PRODUCT_BUNDLE_IDENTIFIER = org.example.Original; }; };
            PROJECT = { isa = PBXProject; targets = ( APP, ); };
        }; rootObject = PROJECT; }
        """.utf8).write(to: file)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private enum MetadataWriteFailure: Error { case failed }

@Test func projectBundleIDTransactionRestoresXcodeOnMetadataWriteFailure() throws {
    let fixture = try BundleIDTransactionFixture()
    defer { fixture.remove() }
    let original = try Data(contentsOf: fixture.file)
    #expect(throws: MetadataWriteFailure.self) {
        try ProjectBundleIDTransaction.update(projectPath: fixture.root.path, bundleID: "org.example.New", scheme: nil, configuration: "Release") {
            let editedText = try String(contentsOf: fixture.file, encoding: .utf8)
        #expect(editedText.contains("org.example.New"))
            throw MetadataWriteFailure.failed
        }
    }
    #expect(try Data(contentsOf: fixture.file) == original)
}

@Test func projectBundleIDTransactionDoesNotOverwriteConcurrentFileEditDuringRollback() throws {
    let fixture = try BundleIDTransactionFixture()
    defer { fixture.remove() }
    let concurrentEdit = Data("concurrent Xcode edit".utf8)
    #expect(throws: ProjectBundleIDTransaction.Failure.self) {
        try ProjectBundleIDTransaction.update(projectPath: fixture.root.path, bundleID: "org.example.New", scheme: nil, configuration: "Release") {
            try concurrentEdit.write(to: fixture.file, options: .atomic)
            throw MetadataWriteFailure.failed
        }
    }
    #expect(try Data(contentsOf: fixture.file) == concurrentEdit)
}

@Test func projectBundleIDTransactionSavesMetadataOnlyAfterValidTargetUpdate() throws {
    let fixture = try BundleIDTransactionFixture()
    defer { fixture.remove() }
    var savedBundleID: String?
    try ProjectBundleIDTransaction.update(projectPath: fixture.root.path, bundleID: "org.example.New", scheme: nil, configuration: "Release") {
        let editedText = try String(contentsOf: fixture.file, encoding: .utf8)
        #expect(editedText.contains("org.example.New"))
        savedBundleID = "org.example.New"
    }
    #expect(savedBundleID == "org.example.New")
    #expect(try String(contentsOf: fixture.file, encoding: .utf8).contains("org.example.New"))
}

@Test func projectBundleIDTransactionRejectsStaleOriginalSnapshotBeforeEditing() throws {
    let fixture = try BundleIDTransactionFixture()
    defer { fixture.remove() }
    let original = try Data(contentsOf: fixture.file)
    var concurrent = try String(contentsOf: fixture.file, encoding: .utf8)
    concurrent = concurrent.replacingOccurrences(of: "org.example.Original", with: "org.example.Concurrent")
    let concurrentData = Data(concurrent.utf8)
    try concurrentData.write(to: fixture.file, options: .atomic)
    #expect(throws: XcodeProjectIdentityEditor.IdentityError.self) {
        try XcodeProjectIdentityEditor().update(projectPath: fixture.root.path, bundleID: "org.example.New",
            configuration: "Release", expectedOriginal: original)
    }
    #expect(try Data(contentsOf: fixture.file) == concurrentData)
}
