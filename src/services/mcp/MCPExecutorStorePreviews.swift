import Foundation

extension MCPRegistry {
    static func previewTools() -> [[String: Any]] {
        let track: [String: Any] = [
            "locale": ["type": "string", "description": "Exact existing Store version locale, e.g. de-DE or en-US."],
            "deviceType": ["type": "string", "enum": MCPStorePreviews.devices.values.flatMap { $0 }.sorted(),
                           "description": "Apple preview device type for the target platform. Use DESKTOP for macOS."]
        ]
        let timeCode = ["type": "string", "description": "Poster time as HH:MM:SS:FF or HH:MM:SS.mmm, e.g. 00:00:06:00 for six seconds."]
        var upload = track
        upload["filePath"] = ["type": "string", "description": "Path relative to the registered project root to one .mp4, .mov or .m4v video."]
        upload["posterTimeCode"] = timeCode
        upload["confirm"] = ["type": "boolean", "enum": [true]]
        var poster = track
        poster["previewId"] = ["type": "string", "description": "Exact existing preview ID from store_previews_list."]
        poster["posterTimeCode"] = timeCode
        poster["confirm"] = ["type": "boolean", "enum": [true]]
        return [
            storeTool(name: "store_previews_list", description: "Read ordered previews, file checksums, Apple processing states and poster times for one version, locale and device.",
                      properties: track, required: ["locale", "deviceType"]),
            storeTool(name: "store_preview_upload", description: "Upload one authorized project video to one version, locale and device. Optionally set its poster after processing. Reuses matching content. After interruption list the same set before retrying; change a missing poster by preview ID.",
                      properties: upload, required: ["locale", "deviceType", "filePath", "confirm"]),
            storeTool(name: "store_preview_set_poster", description: "Set and read back the poster on one authorized, already processed preview in the specified version, locale and device set.",
                      properties: poster, required: ["locale", "deviceType", "previewId", "posterTimeCode", "confirm"])
        ]
    }
}

extension MCPExecutor {
    func executePreviewTool(name: String, arguments: [String: Any], context: MCPStoreContext) async throws -> [String: Any] {
        guard let versionID = context.versionID, let locale = arguments["locale"] as? String,
              let device = arguments["deviceType"] as? String else { throw ReleaseWorkflowError.invalidTarget }
        let previews = try MCPStorePreviews(versionID: versionID, platform: context.platform, locale: locale, deviceType: device) { args, timeout in
            try await context.validate()
            let result = try await context.service.cliExec(args: args, responseTimeoutSeconds: timeout)
            guard result.exitCode == 0 else {
                // A partial media receipt can still identify a stored preview. Verify it against a new list.
                if args.starts(with: ["video-previews", "upload"]),
                   (try? JSONDecoder().decode(MCPStorePreviews.Receipt.self, from: Data(result.stdout.utf8))) != nil {
                    return result.stdout
                }
                throw MCPStorePreviewError("ASC could not complete \(args.prefix(2).joined(separator: " ")) (exit \(result.exitCode)).")
            }
            return result.stdout
        }
        if name == "store_previews_list" { return mcpJSON(try await previews.list()) }
        guard try ReleaseWorkflowArguments.optionalBoolean("confirm", arguments: arguments) else {
            throw ReleaseWorkflowError.confirmationRequired
        }
        let result: [String: Any]
        switch name {
        case "store_preview_upload":
            guard let path = arguments["filePath"] as? String else { throw MCPServerService.MCPError.invalidToolArgs }
            let code = arguments["posterTimeCode"] as? String
            if arguments.keys.contains("posterTimeCode") {
                guard let code else { throw MCPServerService.MCPError.invalidToolArgs }
                try MCPStorePreviews.validateTimeCode(code)
            }
            let file = try MCPStoreFile.stage(relativePath: path, projectRoot: context.projectRoot, allowedExtensions: ["mp4", "m4v", "mov"])
            defer { file.remove() }
            let video = try await MCPStorePreviews.Video.inspect(file.url)
            result = try await previews.upload(video, poster: code)
        case "store_preview_set_poster":
            guard let id = arguments["previewId"] as? String, let code = arguments["posterTimeCode"] as? String else {
                throw MCPServerService.MCPError.invalidToolArgs
            }
            result = try await previews.setPoster(previewID: id, code: code)
        default: throw MCPServerService.MCPError.invalidToolArgs
        }
        var response = mcpJSON(result)
        if result["verified"] as? Bool != true { response["isError"] = true }
        return response
    }
}
