import Foundation
import Testing
@testable import Blitz

@Suite("Version-scoped Store previews")
struct MCPStorePreviewTests {
    private let loc = #"{"data":[{"id":"german-version-loc","type":"appStoreVersionLocalizations","attributes":{"locale":"de-DE"}}]}"#
    private let code = "00:00:06:00"
    private let checksum = "14c4b06b824ec593239362517f538b29"
    private var video: MCPStorePreviews.Video {
        .init(url: URL(fileURLWithPath: "/private/tmp/staged/movie.mp4"), checksum: checksum)
    }

    private final class Fixture {
        var calls = [[String]]()
        var timeouts = [TimeInterval]()
        var outputs: [String?]
        init(_ outputs: [String?]) { self.outputs = outputs }
        func run(_ args: [String], _ timeout: TimeInterval) async throws -> String {
            calls.append(args)
            timeouts.append(timeout)
            guard !outputs.isEmpty, let next = outputs.removeFirst() else { throw MCPStorePreviewError("test transport unavailable") }
            return next
        }
    }

    private func workflow(_ fixture: Fixture) throws -> MCPStorePreviews {
        try MCPStorePreviews(versionID: "version-2-7", platform: "MAC_OS", locale: "de-DE", deviceType: "DESKTOP", run: fixture.run)
    }

    private func inventory(id: String? = nil, poster: String? = nil, state: String = "COMPLETE", digest: String? = nil,
                           assetState: String? = "COMPLETE",
                           localizationID: String = "german-version-loc", device: String = "DESKTOP") throws -> String {
        var previews = [[String: Any]]()
        if let id {
            var attrs: [String: Any] = ["fileName": "movie.mp4", "fileSize": 1234,
                                        "videoDeliveryState": ["state": state],
                                        "videoUrl": "https://example.invalid/?private-token=canary"]
            attrs["assetDeliveryState"] = assetState.map { ["state": $0] }
            attrs["sourceFileChecksum"] = digest
            attrs["previewFrameTimeCode"] = poster
            previews.append(["type": "appPreviews", "id": id, "attributes": attrs])
        }
        let set: [String: Any] = ["type": "appPreviewSets", "id": "osx-set", "attributes": ["previewType": device]]
        return String(decoding: try JSONSerialization.data(withJSONObject: ["versionLocalizationId": localizationID,
            "sets": [["set": set, "previews": previews]]]), as: UTF8.self)
    }

    @Test func listingResolvesTheExactLocaleAndDoesNotReturnSignedURLs() async throws {
        let fixture = Fixture([loc, try inventory(id: "preview-one", poster: code, digest: checksum)])
        let result = try await workflow(fixture).list()
        #expect(fixture.calls[0] == ["localizations", "list", "--type", "version", "--version", "version-2-7",
                                     "--locale", "de-DE", "--paginate", "--output", "json"])
        #expect(fixture.calls[1] == ["video-previews", "list", "--version-localization", "german-version-loc", "--output", "json"])
        #expect(result["setId"] as? String == "osx-set")
        let row = try #require((result["previews"] as? [[String: Any]])?.first)
        #expect(row["previewId"] as? String == "preview-one")
        #expect(row["videoDeliveryState"] as? String == "COMPLETE")
        #expect(row["posterTimeCode"] as? String == code)
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self).contains("private-token"))
    }

    @Test func rejectsForeignLocaleDeviceAndResourceBeforeMutation() async throws {
        let foreignLocale = Fixture([loc.replacingOccurrences(of: "de-DE", with: "en-US")])
        await #expect(throws: MCPStorePreviewError.self) { try await workflow(foreignLocale).upload(video, poster: code) }
        #expect(foreignLocale.calls.count == 1)

        for list in [try inventory(id: "foreign", localizationID: "another-version-loc"),
                     try inventory(id: "foreign", device: "IPHONE_67"), try inventory(id: "other-preview")] {
            let fixture = Fixture([loc, list])
            await #expect(throws: MCPStorePreviewError.self) { try await workflow(fixture).setPoster(previewID: "foreign", code: code) }
            #expect(fixture.calls.count == 2)
        }
        #expect(throws: MCPStorePreviewError.self) {
            try MCPStorePreviews(versionID: "one", platform: "MAC_OS", locale: "de-DE", deviceType: "IPHONE_67", run: foreignLocale.run)
        }
    }

    @Test func acceptsDocumentedFrameFormatsAndRejectsInvalidFields() throws {
        for code in ["00:00:06:00", "00:00:06.000", "00:05:24:29"] { try MCPStorePreviews.validateTimeCode(code) }
        for code in ["00:00:06:30", "00:60:00:00", "6", "00:00:06.00", "00:00:06:00\n"] {
            #expect(throws: MCPStorePreviewError.self) { try MCPStorePreviews.validateTimeCode(code) }
        }
    }

    @Test func interruptedUploadReadsBackOnceAndDoesNotUploadAgain() async throws {
        let fixture = Fixture([loc, try inventory(), nil, try inventory(id: "apple-preview", poster: code, digest: checksum)])
        let result = try await workflow(fixture).upload(video, poster: code)
        #expect(result["verified"] as? Bool == true)
        #expect(fixture.calls[2] == ["video-previews", "upload", "--version-localization", "german-version-loc",
            "--device-type", "DESKTOP", "--path", video.url.path, "--skip-existing", "--output", "json", "--time-code", code])
        #expect(fixture.timeouts[2] == MCPStorePreviews.uploadTimeout)
        #expect(fixture.calls.count == 4)
    }

    @Test func uploadOfExistingContentOnlyUpdatesMissingPoster() async throws {
        let first = try inventory(id: "already-there", poster: "00:00:01:00", digest: checksum)
        let fixture = Fixture([loc, first, nil, try inventory(id: "already-there", poster: code, digest: checksum)])
        let result = try await workflow(fixture).upload(video, poster: code)
        #expect(result["verified"] as? Bool == true)
        #expect(fixture.calls[2] == ["video-previews", "set-poster-frame", "--id", "already-there", "--time-code", code, "--output", "json"])
        let duplicate = Fixture([loc, try inventory(id: "already-there", poster: "00:00:06.000", digest: checksum)])
        #expect(try await workflow(duplicate).upload(video, poster: code)["verified"] as? Bool == true)
        #expect(duplicate.calls.count == 2)
    }

    @Test func unconfirmedAndProcessingPreviewsNeverTriggerAnotherUpload() async throws {
        let pending = try inventory(id: "pending", state: "PROCESSING", digest: checksum)
        let fixture = Fixture([loc, pending])
        let result = try await workflow(fixture).upload(video, poster: code)
        #expect(result["status"] as? String == "processing")
        #expect(result["verified"] as? Bool == false)
        #expect(fixture.calls.count == 2)
        let unknown = Fixture([loc, try inventory(id: "pending", state: "PROCESSING")])
        await #expect(throws: MCPStorePreviewError.self) { try await workflow(unknown).upload(video, poster: code) }
        #expect(unknown.calls.count == 2)
        let uncertain = Fixture([loc, try inventory(), nil, try inventory()])
        await #expect(throws: MCPStorePreviewError.self) { try await workflow(uncertain).upload(video, poster: code) }
        #expect(uncertain.calls.count == 4)
    }

    @Test func receiptCannotVerifyAFileUntilAppleReportsItsChecksum() async throws {
        let receipt = #"{"versionLocalizationId":"german-version-loc","setId":"osx-set","previewType":"DESKTOP","results":[{"assetId":"added"}]}"#
        let fixture = Fixture([loc, try inventory(), receipt, try inventory(id: "added", poster: code, state: "PROCESSING")])
        let result = try await workflow(fixture).upload(video, poster: code)
        #expect(result["verified"] as? Bool == false)
        #expect(result["status"] as? String == "contentUnconfirmed")
        #expect((result["preview"] as? [String: Any])?["previewId"] as? String == "added")
    }

    @Test func staleOrFailedPosterReadbackIsNeverVerified() async throws {
        for state in ["COMPLETE", "FAILED"] {
            let fixture = Fixture([loc, try inventory(id: "existing"), "{}", try inventory(id: "existing", state: state)])
            let result = try await workflow(fixture).setPoster(previewID: "existing", code: code)
            #expect(result["verified"] as? Bool == false)
            #expect(result["status"] as? String == (state == "FAILED" ? "failed" : "posterUnconfirmed"))
        }
    }

    @Test func bothAppleDeliveryStatesMustConfirmCompletion() async throws {
        let combinations: [(String?, String, String)] = [
            ("UPLOAD_COMPLETE", "COMPLETE", "processing"), ("FAILED", "COMPLETE", "failed"),
            ("COMPLETE", "FAILED", "failed"), (nil, "COMPLETE", "deliveryUnconfirmed")
        ]
        for (asset, processing, expected) in combinations {
            let fixture = Fixture([loc, try inventory(id: "existing", poster: code, state: processing, digest: checksum,
                                                     assetState: asset)])
            let result = try await workflow(fixture).upload(video, poster: code)
            #expect(result["verified"] as? Bool == false)
            #expect(result["status"] as? String == expected)
            #expect(fixture.calls.count == 2)
        }
    }

    @Test func renamedNonVideoFailsInspectionBeforeUpload() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("ordinary text".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        await #expect(throws: (any Error).self) { try await MCPStorePreviews.Video.inspect(path) }
    }
}
