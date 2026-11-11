// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import Darwin
import Foundation

/// A small, owned prefix leaves the project's authored instructions intact.
/// File-descriptor-relative access also keeps registered project aliases safe.
enum BlitzWorkflowInstructions {
    static let beginMarker = "<!-- BEGIN BLITZ NEO WORKFLOW ROUTING -->"
    static let endMarker = "<!-- END BLITZ NEO WORKFLOW ROUTING -->"
    private static let installLock = NSLock()

    static func bundledBody() throws -> String {
        guard let url = Bundle.appResources.url(forResource: "blitz-release-instructions", withExtension: "md") else {
            throw failure("The bundled workflow routing instructions are unavailable. Reinstall Blitz Neo before continuing.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func updatedDocument(_ document: String, body: String) throws -> String {
        let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !content.contains("BLITZ NEO WORKFLOW ROUTING") else {
            throw failure("The bundled workflow routing instructions are empty or contain reserved markers.")
        }
        let block = "\(beginMarker)\n\(content)\n\(endMarker)"
        let beginCount = document.components(separatedBy: "<!-- BEGIN BLITZ NEO WORKFLOW ROUTING").count - 1
        let endCount = document.components(separatedBy: "<!-- END BLITZ NEO WORKFLOW ROUTING").count - 1
        if beginCount == 0 && endCount == 0 {
            return block + "\n\n" + document
        }
        guard beginCount == 1, endCount == 1,
              let begin = document.range(of: beginMarker), let end = document.range(of: endMarker),
              begin.upperBound <= end.lowerBound,
              isWholeLine(begin, in: document), isWholeLine(end, in: document) else {
            throw failure("Malformed or duplicate Blitz Neo workflow markers. Repair the marked block manually; authored instructions were not changed.")
        }
        return String(document[..<begin.lowerBound]) + block + String(document[end.upperBound...])
    }

    /// Validate all targets first, including an existing Codex override document.
    /// Used before the older CLAUDE template migration so it cannot follow a link.
    static func validateDocuments(projectDirectory: URL, body: String) throws {
        try withProjectDirectory(projectDirectory) { directory in
            _ = try plans(directory: directory, body: body)
        }
    }

    static func install(projectDirectory: URL, body: String, beforeRename: ((String) throws -> Void)? = nil) throws {
        installLock.lock()
        defer { installLock.unlock() }
        try withProjectDirectory(projectDirectory) { directory in
            let updates = try plans(directory: directory, body: body)
            // Refuse a changed document before starting the batch. Never truncate
            // a file in place: a concurrent reader always sees a whole document.
            for update in updates {
                guard try snapshot(name: update.name, directory: directory) == update.original else {
                    throw failure("\(update.name) changed while preparing workflow instructions. Retry after the edit finishes.")
                }
            }
            for update in updates where update.original?.data != update.data {
                try write(update, directory: directory, beforeRename: beforeRename)
            }
        }
    }

    private struct Snapshot: Equatable {
        let data: Data
        let device: dev_t
        let inode: ino_t
        let permissions: mode_t
    }

    private struct Update {
        let name: String
        let original: Snapshot?
        let data: Data
    }

    private static func plans(directory: Int32, body: String) throws -> [Update] {
        try ["AGENTS.md", "CLAUDE.md", "AGENTS.override.md"].compactMap { name in
            let original = try snapshot(name: name, directory: directory)
            if name == "AGENTS.override.md" && original == nil { return nil }
            guard let existing = String(data: original?.data ?? Data(), encoding: .utf8) else {
                throw failure("\(name) is not UTF-8. Authored instructions were not changed.")
            }
            do {
                return Update(name: name, original: original, data: Data(try updatedDocument(existing, body: body).utf8))
            } catch {
                throw failure("\(name): \(error.localizedDescription)")
            }
        }
    }

    private static func snapshot(name: String, directory: Int32) throws -> Snapshot? {
        var attributes = stat()
        guard fstatat(directory, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw failure("Cannot inspect \(name): \(posixError().localizedDescription)")
        }
        guard attributes.st_mode & S_IFMT == S_IFREG else {
            throw failure("\(name) must be a regular file, not a symlink or directory. Authored instructions were not changed.")
        }
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        defer { _ = Darwin.close(file) }
        var opened = stat()
        guard fstat(file, &opened) == 0,
              opened.st_dev == attributes.st_dev, opened.st_ino == attributes.st_ino,
              opened.st_mode & S_IFMT == S_IFREG else {
            throw failure("\(name) changed while reading workflow instructions.")
        }
        return Snapshot(data: try handle.readToEnd() ?? Data(), device: opened.st_dev,
                        inode: opened.st_ino, permissions: opened.st_mode & 0o777)
    }

    private static func write(_ update: Update, directory: Int32, beforeRename: ((String) throws -> Void)?) throws {
        let staged = ".blitz-workflow-\(UUID().uuidString).tmp"
        let file = openat(directory, staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw posixError() }
        var removeStaged = true
        defer {
            _ = Darwin.close(file)
            if removeStaged { _ = unlinkat(directory, staged, 0) }
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        try handle.write(contentsOf: update.data)
        guard fchmod(file, update.original?.permissions ?? 0o644) == 0 else { throw posixError() }
        guard try snapshot(name: update.name, directory: directory) == update.original else {
            throw failure("\(update.name) changed before saving workflow instructions. Retry after the edit finishes.")
        }
        try beforeRename?(update.name)
        let flags = update.original == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
        guard renameatx_np(directory, staged, directory, update.name, flags) == 0 else { throw posixError() }
        // With RENAME_SWAP the previous file is now at our unique staging name.
        // rename never follows a replacement symlink, including during a race.
        if update.original != nil {
            removeStaged = false
            guard (try? snapshot(name: staged, directory: directory)) == update.original else {
                let conflict = ".blitz-workflow-conflict-\(UUID().uuidString)-\(update.name)"
                let renamed = renameatx_np(directory, staged, directory, conflict, UInt32(RENAME_EXCL)) == 0
                let retainedName = renamed ? conflict : staged
                let retainedPath = try path(of: directory, child: retainedName)
                throw failure("\(update.name) changed during installation. The concurrent edit was preserved at \(retainedPath). Reconcile that file before retrying; no further documents were updated.")
            }
            removeStaged = true
        }
    }

    private static func path(of directory: Int32, child: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(directory, F_GETPATH, &buffer) == 0 else {
            throw failure("A concurrent edit was retained as \(child) in the project directory, but its absolute path could not be resolved. Reconcile it before retrying.")
        }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true).appendingPathComponent(child).path
    }

    private static func withProjectDirectory<T>(_ project: URL, operation: (Int32) throws -> T) throws -> T {
        // Imported projects are intentionally registered by directory symlink.
        // Freeze that canonical directory; no child instruction symlink is allowed.
        let canonical = project.resolvingSymlinksInPath().standardizedFileURL
        let directory = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw failure("Cannot open project directory: \(posixError().localizedDescription)") }
        defer { _ = Darwin.close(directory) }
        return try operation(directory)
    }

    private static func isWholeLine(_ range: Range<String.Index>, in text: String) -> Bool {
        let prefix = text[..<range.lowerBound]
        let startsLine = prefix.isEmpty || prefix.hasSuffix("\n") || prefix.hasSuffix("\r\n")
        let remainder = text[range.upperBound...]
        return startsLine && (remainder.isEmpty || remainder.hasPrefix("\n") || remainder.hasPrefix("\r\n"))
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "BlitzWorkflowInstructions", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
