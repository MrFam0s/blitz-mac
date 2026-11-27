import AVFoundation
import CryptoKit
import Foundation

struct MCPStorePreviewError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct MCPStorePreviews {
    typealias Runner = ([String], TimeInterval) async throws -> String
    // ASC can wait 30 minutes for another media upload and up to one hour for a large file.
    static let uploadTimeout: TimeInterval = 5_700
    static let devices = [
        "IOS": ["IPHONE_DUO", "IPHONE_69", "IPHONE_67", "IPHONE_65", "IPHONE_61", "IPHONE_58", "IPHONE_55",
                "IPHONE_47", "IPHONE_40", "IPHONE_35", "IPAD_PRO_3GEN_129", "IPAD_PRO_3GEN_11",
                "IPAD_PRO_129", "IPAD_105", "IPAD_97"],
        "MAC_OS": ["DESKTOP"], "TV_OS": ["APPLE_TV"], "VISION_OS": ["APPLE_VISION_PRO"]
    ]

    let versionID: String
    let locale: String
    let device: String
    let run: Runner

    init(versionID: String, platform: String, locale: String, deviceType: String, run: @escaping Runner) throws {
        guard ReleaseWorkflowTarget.validID(versionID),
              locale.utf8.count <= 40, locale.range(of: #"\A[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*\z"#, options: .regularExpression) != nil,
              Self.devices[platform]?.contains(deviceType) == true else {
            throw MCPStorePreviewError("Select an exact version, locale, and preview device type for that platform (macOS uses DESKTOP).")
        }
        self.versionID = versionID
        self.locale = locale
        self.device = deviceType == "IPHONE_69" ? "IPHONE_67" : deviceType
        self.run = run
    }

    static func validateTimeCode(_ code: String) throws {
        guard code.range(of: #"\A[0-9]{2}:[0-5][0-9]:[0-5][0-9](:[0-2][0-9]|\.[0-9]{3})\z"#, options: .regularExpression) != nil else {
            throw MCPStorePreviewError("Use HH:MM:SS:FF (frames 00–29) or HH:MM:SS.mmm for the poster.")
        }
    }

    private func posterMatches(_ saved: String?, _ desired: String?) -> Bool {
        guard let desired else { return true }
        guard let saved else { return false }
        if saved == desired { return true }
        // Whole seconds are equivalent at every frame rate in Apple's two timecode formats.
        if desired.hasSuffix(".000") { return saved == desired.dropLast(4) + ":00" }
        if desired.hasSuffix(":00") { return saved == desired.dropLast(3) + ".000" }
        return false
    }

    struct Video {
        let url: URL
        let checksum: String

        static func inspect(_ url: URL) async throws -> Self {
            let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else { throw MCPStorePreviewError("The selected file must contain a video track.") }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = Insecure.MD5()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                digest.update(data: chunk)
            }
            return Self(url: url, checksum: digest.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }

    struct Resource<Attributes: Decodable>: Decodable {
        let id, type: String
        let attributes: Attributes
    }
    struct Localization: Decodable { let locale: String }
    struct Localizations: Decodable { let data: [Resource<Localization>] }
    struct SetAttributes: Decodable { let previewType: String }
    struct Delivery: Decodable {
        struct Issue: Decodable { let code: String? }
        let state: String?
        let errors: [Issue]?
    }
    struct Attributes: Decodable {
        let fileName: String
        let fileSize: Int64
        let sourceFileChecksum, previewFrameTimeCode: String?
        let assetDeliveryState, videoDeliveryState: Delivery?
    }
    typealias Preview = Resource<Attributes>
    struct Track: Decodable {
        let set: Resource<SetAttributes>
        let previews: [Preview]
        private enum CodingKeys: String, CodingKey { case set, previews }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            set = try fields.decode(Resource<SetAttributes>.self, forKey: .set)
            // An empty Go slice can encode as null. A missing relationship is not a verified empty set.
            previews = try fields.decodeNil(forKey: .previews) ? [] : fields.decode([Preview].self, forKey: .previews)
        }
    }
    struct List: Decodable {
        let versionLocalizationId: String
        let sets: [Track]
    }
    struct Receipt: Decodable {
        struct Item: Decodable { let assetId: String }
        let versionLocalizationId, setId, previewType: String
        let results: [Item]
    }
    struct Inventory {
        let localizationID: String
        let setID: String?
        let previews: [Preview]
    }

    private func read<T: Decodable>(_ arguments: [String], as: T.Type) async throws -> T {
        let output = try await run(arguments + ["--output", "json"], 60)
        do { return try JSONDecoder().decode(T.self, from: Data(output.utf8)) }
        catch { throw MCPStorePreviewError("ASC returned incomplete preview information. Refresh the preview list before continuing.") }
    }

    func inventory() async throws -> Inventory {
        let localizations = try await read(["localizations", "list", "--type", "version", "--version", versionID,
                                            "--locale", locale, "--paginate"], as: Localizations.self)
        let matches = localizations.data.filter { $0.attributes.locale == locale }
        guard matches.count == 1, let row = matches.first, row.type == "appStoreVersionLocalizations",
              ReleaseWorkflowTarget.validID(row.id) else {
            throw MCPStorePreviewError("This version must have exactly one Store localization for \(locale).")
        }
        return try await inventory(localizationID: row.id)
    }

    private func inventory(localizationID: String) async throws -> Inventory {
        let list = try await read(["video-previews", "list", "--version-localization", localizationID], as: List.self)
        let tracks = list.sets.filter { $0.set.attributes.previewType == device }
        guard list.versionLocalizationId == localizationID, tracks.count <= 1 else {
            throw MCPStorePreviewError("Apple returned an unexpected localization or multiple preview sets for this device.")
        }
        let track = tracks.first
        let previews = track?.previews ?? []
        if let track {
            guard track.set.type == "appPreviewSets", ReleaseWorkflowTarget.validID(track.set.id),
                  previews.allSatisfy({ $0.type == "appPreviews" && ReleaseWorkflowTarget.validID($0.id) }),
                  Set(previews.map(\.id)).count == previews.count else {
                throw MCPStorePreviewError("The preview set contains ambiguous or invalid Apple resource IDs.")
            }
        }
        return Inventory(localizationID: localizationID, setID: track?.set.id, previews: previews)
    }

    private func scope(_ inventory: Inventory) -> [String: Any] {
        var result: [String: Any] = ["versionId": versionID, "locale": locale,
            "versionLocalizationId": inventory.localizationID, "deviceType": device]
        result["setId"] = inventory.setID
        return result
    }

    private func summary(_ preview: Preview) -> [String: Any] {
        let a = preview.attributes
        var row: [String: Any] = ["previewId": preview.id, "fileName": a.fileName, "fileSize": a.fileSize]
        row["assetDeliveryState"] = a.assetDeliveryState?.state
        row["videoDeliveryState"] = a.videoDeliveryState?.state
        row["posterTimeCode"] = a.previewFrameTimeCode
        row["sourceFileChecksum"] = a.sourceFileChecksum
        let codes = ((a.assetDeliveryState?.errors ?? []) + (a.videoDeliveryState?.errors ?? [])).compactMap(\.code)
        if !codes.isEmpty { row["deliveryErrorCodes"] = codes }
        return row
    }

    func list() async throws -> [String: Any] {
        let inventory = try await inventory()
        var result = scope(inventory)
        result["previews"] = inventory.previews.map(summary)
        return result
    }

    private func outcome(_ preview: Preview, in inventory: Inventory, desiredPoster: String?, contentVerified: Bool = true) -> [String: Any] {
        let a = preview.attributes
        var result = scope(inventory)
        let states = [a.assetDeliveryState?.state, a.videoDeliveryState?.state]
        let failed = states.contains("FAILED")
        let processed = a.videoDeliveryState?.state == "COMPLETE" && a.assetDeliveryState?.state == "COMPLETE"
        let matchesPoster = posterMatches(a.previewFrameTimeCode, desiredPoster)
        result["preview"] = summary(preview)
        result["verified"] = contentVerified && processed && matchesPoster
        if failed {
            result["status"] = "failed"
            result["nextAction"] = "Inspect the Apple processing error for this preview before changing the set."
        } else if !contentVerified {
            result["status"] = "contentUnconfirmed"
            result["nextAction"] = "List this set again to verify its checksum and processing state."
        } else if a.videoDeliveryState?.state == nil || a.assetDeliveryState?.state == nil {
            result["status"] = "deliveryUnconfirmed"
            result["nextAction"] = "List this set again to verify Apple's file delivery and video processing states."
        } else if !processed {
            result["status"] = "processing"
            result["nextAction"] = "List this set again after processing. If needed, set the poster using the existing preview ID."
        } else {
            result["status"] = matchesPoster ? "verified" : "posterUnconfirmed"
            if !matchesPoster {
                result["nextAction"] = "Check the poster on this preview ID using store_previews_list before setting it again."
            }
        }
        result["requestedPosterTimeCode"] = desiredPoster
        return result
    }

    func setPoster(previewID: String, code: String) async throws -> [String: Any] {
        try Self.validateTimeCode(code)
        guard ReleaseWorkflowTarget.validID(previewID) else { throw ReleaseWorkflowError.invalidTarget }
        let before = try await inventory()
        guard let preview = before.previews.first(where: { $0.id == previewID }) else {
            throw MCPStorePreviewError("The preview is not in this version, locale and device set.")
        }
        return try await setPoster(preview: preview, in: before, code: code)
    }

    private func setPoster(preview: Preview, in before: Inventory, code: String) async throws -> [String: Any] {
        let current = outcome(preview, in: before, desiredPoster: code)
        guard current["status"] as? String == "posterUnconfirmed" else { return current }
        // A transport failure can occur after Apple applied the PATCH. Reconcile the same preview once.
        _ = try? await run(["video-previews", "set-poster-frame", "--id", preview.id, "--time-code", code, "--output", "json"], 60)
        let after = try await readBack(before)
        guard let updated = after.previews.first(where: { $0.id == preview.id }) else {
            throw MCPStorePreviewError("Poster write unconfirmed. List the same preview set before taking further action.")
        }
        return outcome(updated, in: after, desiredPoster: code)
    }

    private func readBack(_ before: Inventory) async throws -> Inventory {
        guard let after = try? await inventory(localizationID: before.localizationID),
              before.setID == nil || after.setID == before.setID else {
            throw MCPStorePreviewError("Preview write unconfirmed. Use store_previews_list on the same version, locale and device. Do not repeat the upload.")
        }
        return after
    }

    func upload(_ video: Video, poster: String?) async throws -> [String: Any] {
        if let poster { try Self.validateTimeCode(poster) }
        let before = try await inventory()
        let matches = before.previews.filter { $0.attributes.sourceFileChecksum?.lowercased() == video.checksum }
        guard matches.count <= 1 else {
            throw MCPStorePreviewError("Several previews have this checksum. Select an exact previewId before changing its poster.")
        }
        if let existing = matches.first {
            if let poster { return try await setPoster(preview: existing, in: before, code: poster) }
            return outcome(existing, in: before, desiredPoster: nil)
        }
        guard !before.previews.contains(where: {
            $0.attributes.fileName == video.url.lastPathComponent && ($0.attributes.sourceFileChecksum ?? "").isEmpty
        }) else {
            throw MCPStorePreviewError("Apple already has a preview with this filename and an unconfirmed checksum. List the set again after processing.")
        }
        guard before.previews.count < 3 else {
            throw MCPStorePreviewError("This device set already has three previews.")
        }
        var arguments = ["video-previews", "upload", "--version-localization", before.localizationID, "--device-type", device,
                         "--path", video.url.path, "--skip-existing", "--output", "json"]
        if let poster { arguments += ["--time-code", poster] }
        let output = try? await run(arguments, Self.uploadTimeout)
        let receipt = output.flatMap { try? JSONDecoder().decode(Receipt.self, from: Data($0.utf8)) }
        let after = try await readBack(before)
        let observed = after.previews.filter { $0.attributes.sourceFileChecksum?.lowercased() == video.checksum }
        if observed.count == 1, let preview = observed.first {
            return outcome(preview, in: after, desiredPoster: poster)
        }
        if observed.isEmpty, let receipt, receipt.versionLocalizationId == after.localizationID, receipt.setId == after.setID,
           receipt.previewType == device, receipt.results.count == 1,
           let preview = after.previews.first(where: { $0.id == receipt.results[0].assetId }),
           preview.attributes.fileName == video.url.lastPathComponent, (preview.attributes.sourceFileChecksum ?? "").isEmpty {
            return outcome(preview, in: after, desiredPoster: poster, contentVerified: false)
        }
        throw MCPStorePreviewError("Upload unconfirmed. Use store_previews_list on the same version, locale and device to check the file and checksum before attempting another upload.")
    }
}
