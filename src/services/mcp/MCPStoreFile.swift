import Darwin
import Foundation

/// Give the media helper a private snapshot. Traverse relative to directory handles so a
/// concurrent symlink replacement cannot redirect an approved upload outside the project.
struct MCPStoreFile {
    let url: URL
    func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    static func stage(relativePath: String, projectRoot: URL, allowedExtensions: Set<String>,
                      maxBytes: Int64 = 500 * 1024 * 1024) throws -> Self {
        let invalid = ASCError.notFound("Choose a regular file inside the registered project with a supported extension.")
        let parts = relativePath.components(separatedBy: "/")
        let disallowed: Set<String> = ["", ".", "..", ".git", ".agents", ".codex", ".claude"]
        guard !relativePath.utf8.contains(0), parts.allSatisfy({ !disallowed.contains($0.lowercased()) }),
              let name = parts.last, allowedExtensions.contains((name as NSString).pathExtension.lowercased()) else { throw invalid }
        var parent = open(projectRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw invalid }
        defer { close(parent) }
        for part in parts.dropLast() {
            let fd = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw invalid }
            close(parent)
            parent = fd
        }
        let source = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw invalid }
        defer { close(source) }
        var original = stat()
        guard fstat(source, &original) == 0, (original.st_mode & S_IFMT) == S_IFREG,
              original.st_size > 0, original.st_size <= maxBytes else { throw invalid }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = Self(url: directory.appendingPathComponent(name))
        do {
            let dest = open(file.url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard dest >= 0 else { throw ReleaseWorkflowError.storage }
            defer { close(dest) }
            guard fcopyfile(source, dest, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else { throw ReleaseWorkflowError.storage }
            var after = stat(), copied = stat()
            guard fstat(source, &after) == 0, fstat(dest, &copied) == 0, copied.st_size == original.st_size,
                  after.st_size == original.st_size, after.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec else { throw invalid }
            return file
        } catch {
            file.remove()
            throw error
        }
    }
}
