// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Foundation

/// AXe addresses CoreSimulator devices by UDID and reports the settled hinge
/// and display. Probe the CLI without touching a device before attempting a move.
struct AXeSimulatorHinge {
    typealias Run = (String, [String]) async throws -> String
    let candidates: [String]
    let run: Run

    init(candidates: [String]? = nil, run: @escaping Run = { try await ProcessRunner.run($0, arguments: $1) }) {
        // Finder does not import the interactive shell PATH. Never search the project directory.
        let fm = FileManager.default
        self.candidates = candidates ?? [
            "/opt/homebrew/bin/axe", "/usr/local/bin/axe",
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/axe").path, "/opt/local/bin/axe"
        ].filter { path in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue && fm.isExecutableFile(atPath: path)
        }
        self.run = run
    }

    private struct Response<Payload: Decodable>: Decodable {
        let command: String
        let didError: Bool
        let data: Payload
    }

    private struct Help: Decodable { let messages: [String] }

    func supportedExecutable() async -> String? {
        for path in candidates {
            guard let output = try? await run(path, ["--output", "json", "hinge", "set", "--help"]),
                  let help = try? JSONDecoder().decode(Response<Help>.self, from: Data(output.utf8)), !help.didError else { continue }
            // Unsupported subcommands can return the general help with exit code zero.
            let lines = help.data.messages.flatMap { $0.split(whereSeparator: \.isNewline) }
            if lines.contains(where: { $0.hasPrefix("USAGE: axe hinge set ") && $0.contains("--udid") }) { return path }
        }
        return nil
    }

    private struct SetResponse: Decodable {
        struct Result: Decodable {
            struct Hinge: Decodable {
                let degrees: Double
                let mechanicalDegrees: Double
                let posture: String
            }
            struct Screen: Decodable { let role: String }
            let udid: String
            let hinge: Hinge
            let activeScreen: Screen
        }
        let result: Result
    }

    private struct Failure: Decodable {
        struct Detail: Decodable { let code: String; let message: String }
        let error: Detail
    }

    func set(_ pose: SimulatorPose, on udid: String, using path: String) async throws -> SimulatorPose.Outcome {
        let argument = pose == .partiallyOpen ? "tabletop" : pose.rawValue
        let expectedAngle: Double
        switch pose {
        case .closed: expectedAngle = 0
        case .partiallyOpen: expectedAngle = 90
        case .open: expectedAngle = 180
        }
        let output: String
        do {
            output = try await run(path, ["--output", "json", "hinge", "set", argument, "--udid", udid])
        } catch let error as ProcessRunner.ProcessError {
            guard let detail = try? JSONDecoder().decode(Failure.self, from: Data(error.stderr.utf8)).error else { throw error }
            throw SimulatorPose.PoseError.axeFailure(detail.code, detail.message)
        }
        guard let response = try? JSONDecoder().decode(Response<SetResponse>.self, from: Data(output.utf8)),
              !response.didError, response.command == "hinge set" else { throw SimulatorPose.PoseError.unconfirmed }
        let result = response.data.result
        guard result.udid.caseInsensitiveCompare(udid) == .orderedSame, result.hinge.posture == pose.rawValue,
              abs(result.hinge.mechanicalDegrees - expectedAngle) <= 0.5,
              (0...180).contains(result.hinge.degrees), ["inner", "outer"].contains(result.activeScreen.role)
        else { throw SimulatorPose.PoseError.unconfirmed }
        return .confirmed(degrees: result.hinge.degrees, activeDisplay: result.activeScreen.role)
    }
}
