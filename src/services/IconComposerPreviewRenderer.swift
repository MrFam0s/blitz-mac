// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Security

/// Renders the complete Icon Composer document, including its background and
/// materials. Call off the main actor: a layer's source PNG is not an app icon.
enum IconComposerPreviewRenderer {
    private static let renderLock = NSLock()
    private static let pixels = 1024

    static func render(packageURL: URL, platform: String, cacheKey: String,
                       isSourceCurrent: @Sendable () -> Bool = { true }) -> URL? {
        guard let executable = rendererExecutable(),
              let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let version = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return render(packageURL: packageURL, platform: platform, cacheKey: cacheKey,
            rendererVersion: "\(executable.path)|\(version)",
            cacheDirectory: cache.appendingPathComponent("org.amosystems.BlitzNeo/IconComposer", isDirectory: true),
            isSourceCurrent: isSourceCurrent) { package, output, platform in
                runProcess(executableURL: executable, arguments: [package.path,
                    "--export-image", "--output-file", output.path, "--platform", platform,
                    "--rendition", "Default", "--width", String(pixels), "--height", String(pixels), "--scale", "1"],
                    timeout: 12)
            }
    }

    /// The renderer and cache location are injectable for offline tests. Cache
    /// keys include the document fingerprint, platform and renderer revision.
    static func render(packageURL: URL, platform: String, cacheKey: String, rendererVersion: String,
                       cacheDirectory: URL,
                       isSourceCurrent: @Sendable () -> Bool = { true },
                       renderImage: (URL, URL, String) -> Bool) -> URL? {
        guard ["macOS", "iOS"].contains(platform), !cacheKey.isEmpty,
              packageURL.pathExtension == "icon" else { return nil }
        let fm = FileManager.default
        let keyData = Data("icon-composer-preview-v1|\(cacheKey)|\(platform)|\(rendererVersion)".utf8)
        let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
        let cached = cacheDirectory.appendingPathComponent(key + ".png")
        // Serialize duplicate view loads; the second caller reuses the first
        // complete render. No partially written preview is ever exposed.
        renderLock.lock()
        defer { renderLock.unlock() }
        // The document may have changed while this request waited for another
        // render. Never reuse or publish bytes under an obsolete fingerprint.
        guard isSourceCurrent() else { return nil }
        if isValidPreview(cached) { return cached }
        do {
            try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard (try? cacheDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
            let staged = cacheDirectory.appendingPathComponent(".render-\(UUID().uuidString).png")
            defer { try? fm.removeItem(at: staged) }
            guard isSourceCurrent(), renderImage(packageURL, staged, platform),
                  isValidPreview(staged), isSourceCurrent() else { return nil }
            // POSIX rename atomically replaces a corrupt entry or a concurrent
            // process's same-key render, without an absent-file interval.
            let result = staged.path.withCString { source in
                cached.path.withCString { destination in Darwin.rename(source, destination) }
            }
            return result == 0 ? cached : nil
        } catch { return nil }
    }

    private static func isValidPreview(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        return image.width == pixels && image.height == pixels
    }

    /// Xcode's Developer/usr/bin/ictool is a compiler with a different CLI.
    /// Export previews through Icon Composer's own Apple-signed executable.
    static func rendererExecutable() -> URL? {
        var candidates: [URL] = []
        let output = Pipe()
        if runProcess(executableURL: URL(fileURLWithPath: "/usr/bin/xcode-select"),
                      arguments: ["-p"], timeout: 2, standardOutput: output.fileHandleForWriting) {
            try? output.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readData(ofLength: 8192)
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, path.hasPrefix("/") {
                candidates.append(URL(fileURLWithPath: path).deletingLastPathComponent()
                    .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool"))
            }
        } else { try? output.fileHandleForWriting.close() }
        try? output.fileHandleForReading.close()
        candidates.append(URL(fileURLWithPath: "/Applications/Icon Composer.app/Contents/Executables/ictool"))
        candidates.append(URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"))
        return candidates.first(where: isAppleRenderer)
    }

    private static func isAppleRenderer(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString("anchor apple and identifier \"com.apple.IconComposerTool\"" as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    /// No shell, inherited terminal input or accumulating diagnostic output.
    /// A stalled Apple tool must never keep dashboard hydration waiting forever.
    static func runProcess(executableURL: URL, arguments: [String], timeout: TimeInterval,
                           standardOutput: FileHandle = .nullDevice) -> Bool {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return false }
        guard exited.wait(timeout: .now() + max(0.01, timeout)) == .success else {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 0.25) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = exited.wait(timeout: .now() + 0.5)
            }
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
}
