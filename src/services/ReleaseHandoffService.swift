import Foundation

struct ReleaseHandoffPackage {
    let instructions: String
    let document: URL
    let productFacts: URL
}

/// Files shared by the existing development chat and the embedded terminal.
/// Product facts are ordinary project documentation. Handoffs contain local paths
/// and account identifiers and live in an ignored, private directory.
enum ReleaseHandoffService {
    private static let fm = FileManager.default

    static func prepare(context: ReleaseAutomationContext, preflight: ReleasePreflight) throws -> ReleaseHandoffPackage {
        guard let account = context.accountKey, !account.isEmpty else {
            throw failure("Das Apple-Konto fehlt im Release-Auftrag. Bitte den Dialog erneut öffnen.")
        }
        let root = URL(fileURLWithPath: context.projectPath, isDirectory: true)
        let facts = try prepareProductFacts(projectDirectory: root)
        let directory = try privateDirectory(projectDirectory: root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let factsPath = String(decoding: try encoder.encode(facts.path), as: UTF8.self)
        let statePath = String(decoding: try encoder.encode(directory.path), as: UTF8.self)
        let instructions = """
        Continue this explicitly requested release in the current development chat. Use the project's blitz-release skill.
        Read product facts at \(factsPath), then verify them against the actual source and tested build. Missing facts are unknown; chat history alone is not evidence. Update that document only with verified facts and preserve existing authored content.
        The private handoff directory is \(statePath). Do not commit handoffs, operation journals, credentials or demo-account secrets.

        """ + (try ReleaseAutomationService.prompt(context: context, preflight: preflight))
        let document = directory.appendingPathComponent("release-\(UUID().uuidString).md")
        try createFile(Data(instructions.utf8), at: document, mode: 0o600)
        return ReleaseHandoffPackage(instructions: instructions, document: document, productFacts: facts)
    }

    @discardableResult
    static func prepareProductFacts(projectDirectory: URL) throws -> URL {
        let root = try canonicalProject(projectDirectory)
        let docs = try directory(root.appendingPathComponent("docs"), inside: root, mode: 0o755)
        let target = docs.appendingPathComponent("blitz-product.md")
        try validatePath(target, inside: root)
        if fm.fileExists(atPath: target.path) {
            guard try target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw failure("Die Produktdokumentation ist keine normale Datei.")
            }
            return target
        }
        guard let template = Bundle.appResources.url(forResource: "release-product-facts", withExtension: "md") else {
            throw failure("Die Vorlage für Produktinformationen fehlt im App-Bundle.")
        }
        try createFile(Data(contentsOf: template), at: target, mode: 0o644)
        return target
    }

    static func writeCreationIdentity(_ values: [String: String], projectDirectory: URL, operationID: UUID) throws -> URL {
        let directory = try privateDirectory(projectDirectory: projectDirectory)
        let file = directory.appendingPathComponent("app-creation-\(operationID.uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try validatePath(file, inside: try canonicalProject(projectDirectory))
        if fm.fileExists(atPath: file.path) {
            guard try Data(contentsOf: file) == data else {
                throw failure("Die gespeicherte App-Identität weicht vom bestätigten Vorgang ab.")
            }
        } else {
            try createFile(data, at: file, mode: 0o600)
        }
        return file
    }

    private static func privateDirectory(projectDirectory: URL) throws -> URL {
        let root = try canonicalProject(projectDirectory)
        let blitz = try directory(root.appendingPathComponent(".blitz"), inside: root, mode: 0o700)
        let target = try directory(blitz.appendingPathComponent("release-handoff"), inside: root, mode: 0o700)
        let ignore = target.appendingPathComponent(".gitignore")
        try validatePath(ignore, inside: root)
        if fm.fileExists(atPath: ignore.path) {
            guard try String(contentsOf: ignore, encoding: .utf8) == "*\n" else {
                throw failure("Der private Übergabeordner ist nicht vollständig von Git ausgeschlossen.")
            }
        } else { try createFile(Data("*\n".utf8), at: ignore, mode: 0o600) }
        return target
    }

    private static func canonicalProject(_ project: URL) throws -> URL {
        let root = project.standardizedFileURL.resolvingSymlinksInPath()
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw failure("Der Projektordner ist nicht erreichbar.")
        }
        return root
    }

    private static func directory(_ url: URL, inside root: URL, mode: Int) throws -> URL {
        try validatePath(url, inside: root)
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: mode])
        }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw failure("Ein benötigter Projektpfad ist kein Ordner.")
        }
        return url
    }

    private static func validatePath(_ url: URL, inside root: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw failure("Der Übergabepfad liegt außerhalb des Projekts.") }
        var candidate = url
        while candidate.path != root.path {
            if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw failure("Übergabedateien dürfen keine symbolischen Verknüpfungen verwenden.")
            }
            candidate.deleteLastPathComponent()
        }
    }

    private static func createFile(_ data: Data, at url: URL, mode: Int) throws {
        try data.write(to: url, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "BlitzReleaseHandoff", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
