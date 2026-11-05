import AppKit
import ImageIO
import SwiftUI

private enum ProjectAppIconLookupState {
    case unresolved
    case resolved(ProjectIconSource)
    case missing
}

private enum ProjectIconSource {
    case raster(String)
    case composer(ProjectIconComposerSource)
    case unavailableComposer(String)
}

enum ProjectAppIconLoader {
    static let didInvalidateNotification = Notification.Name("ProjectAppIconLoader.didInvalidate")

    private static let imageCache = NSCache<NSString, NSImage>()
    private static let lock = NSLock()
    private static var pathCache: [String: ProjectAppIconLookupState] = [:]
    private static var cacheRevisions: [String: Int] = [:]
    private static let skippedDirectories: Set<String> = [
        "node_modules",
        "Pods",
        ".git",
        ".build",
        "DerivedData",
        "build", "target", "vendor", "deps", "ThirdParty"
    ]

    static func cachedImage(for projectId: String) -> NSImage? {
        imageCache.object(forKey: projectId as NSString)
    }

    static func loadImage(for projectId: String, projectPath: String) async -> NSImage? {
        let revision = cacheState(for: projectId).revision
        if let cached = cachedImage(for: projectId) {
            return cached
        }

        guard let path = await loadPath(for: projectId, projectPath: projectPath),
              let image = NSImage(contentsOfFile: path) else {
            return nil
        }

        return cacheImage(image, for: projectId, revision: revision) ? image : nil
    }

    static func loadStatus(for projectId: String, projectPath: String) async -> String? {
        guard let source = await loadSource(for: projectId, projectPath: projectPath) else { return nil }
        if case .unavailableComposer = source { return nil }
        // Configuration is independent of preview-tool availability or rendering.
        if case .raster(let path) = source, path.hasSuffix("assets/AppIcon/icon_1024.png") { return "1024px" }
        return "Configured"
    }

    static func refreshImage(for projectId: String, projectPath: String) async -> NSImage? {
        resetCache(for: projectId)
        return await loadImage(for: projectId, projectPath: projectPath)
    }

    static func invalidate(for projectId: String) {
        resetCache(for: projectId)
        NotificationCenter.default.post(name: didInvalidateNotification, object: projectId)
    }

    static func composerPackagePath(for projectId: String, projectPath: String) async -> String? {
        switch await loadSource(for: projectId, projectPath: projectPath) {
        case .composer(let source): return source.packageURL.path
        case .unavailableComposer(let path): return path
        default: return nil
        }
    }

    static func loadPath(for projectId: String, projectPath: String,
                         renderComposer: @escaping @Sendable (URL, String, String) -> URL? = { package, platform, key in
                             IconComposerPreviewRenderer.render(packageURL: package, platform: platform, cacheKey: key,
                                 isSourceCurrent: {
                                     ProjectIconComposerSource(packageURL: package, projectRoot: package.deletingLastPathComponent())?.cacheKey == key
                                 })
                         }) async -> String? {
        let revision = cacheState(for: projectId).revision
        guard let source = await loadSource(for: projectId, projectPath: projectPath) else { return nil }
        let path: String?
        switch source {
        case .raster(let raster): path = raster
        case .unavailableComposer: path = nil
        case .composer(let composer):
            path = await Task.detached(priority: .utility) {
                renderComposer(composer.packageURL, composer.platform, composer.cacheKey)?.path
            }.value
        }
        // A render completing after Refresh must not return the previous icon.
        return cacheState(for: projectId).revision == revision ? path : nil
    }

    private static func loadSource(for projectId: String, projectPath: String) async -> ProjectIconSource? {
        let state = cacheState(for: projectId)
        if case .resolved(let source) = state.path { return source }
        let source = await Task.detached(priority: .utility) {
            findIconSource(projectPath: projectPath)
        }.value
        return cachePath(source, for: projectId, revision: state.revision) ? source : nil
    }

    private static func cacheState(for projectId: String) -> (path: ProjectAppIconLookupState, revision: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (pathCache[projectId] ?? .unresolved, cacheRevisions[projectId] ?? 0)
    }

    private static func cachePath(_ path: ProjectIconSource?, for projectId: String, revision: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard revision == cacheRevisions[projectId, default: 0] else { return false }
        pathCache[projectId] = path.map(ProjectAppIconLookupState.resolved) ?? .missing
        return true
    }

    private static func cacheImage(_ image: NSImage, for projectId: String, revision: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard revision == cacheRevisions[projectId, default: 0] else { return false }
        imageCache.setObject(image, forKey: projectId as NSString)
        return true
    }

    private static func resetCache(for projectId: String) {
        lock.lock()
        defer { lock.unlock() }
        // Older detached scans must not repopulate either cache after a refresh.
        cacheRevisions[projectId, default: 0] += 1
        pathCache.removeValue(forKey: projectId)
        imageCache.removeObject(forKey: projectId as NSString)
    }

    private static func findIconSource(projectPath: String) -> ProjectIconSource? {
        let fm = FileManager.default
        let projectDir = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath()
        var candidates: [IconCandidate] = []
        var composers: [ProjectIconComposerSource] = []
        var composerPackages: [URL] = []
        var projectFiles: [URL] = []
        let generatedIcon = projectDir.appendingPathComponent("assets/AppIcon/icon_1024.png")
        // The Xcode catalog is the app's icon source. Generated working copies can
        // outlive a redesign and are only a fallback when no usable catalog exists.
        guard let enumerator = fm.enumerator(
            at: projectDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return IconCandidate(url: generatedIcon, priority: 0).map { .raster($0.url.path) }
        }

        while let entry = enumerator.nextObject() as? URL {
            let name = entry.lastPathComponent

            if skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }

            if entry.pathExtension == "icon" {
                enumerator.skipDescendants()
                let package = entry.resolvingSymlinksInPath().standardizedFileURL
                if package.path.hasPrefix(projectDir.path + "/"),
                   (try? package.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    composerPackages.append(package)
                }
                if let source = ProjectIconComposerSource(packageURL: entry, projectRoot: projectDir) {
                    composers.append(source)
                }
                continue
            }
            if name == "project.pbxproj", entry.deletingLastPathComponent().pathExtension == "xcodeproj" {
                projectFiles.append(entry)
            }

            guard name == "Contents.json",
                  entry.deletingLastPathComponent().lastPathComponent == "AppIcon.appiconset",
                  let data = fm.contents(atPath: entry.path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let images = json["images"] as? [[String: Any]] else {
                continue
            }

            for image in images {
                guard let filename = image["filename"] as? String else { continue }
                let directory = entry.deletingLastPathComponent().resolvingSymlinksInPath()
                let url = directory.appendingPathComponent(filename).resolvingSymlinksInPath()
                guard url.deletingLastPathComponent() == directory else { continue }
                let appearances = image["appearances"] as? [[String: Any]] ?? []
                if let candidate = IconCandidate(url: url, priority: appearances.isEmpty ? 1 : 0) {
                    candidates.append(candidate)
                }
            }
        }
        let eligible: [ProjectIconComposerSource]
        if projectFiles.isEmpty {
            // Without target membership, a loose document must not displace an
            // existing catalog. Still support a sole document in a new project.
            eligible = candidates.isEmpty ? composers : []
        } else {
            let configured = projectFiles.reduce(into: Set<URL>()) {
                $0.formUnion(ProjectIconComposerSelection.configuredPackages(in: $1, candidates: composerPackages))
            }
            // A broken or missing configured document must not be masked by an
            // obsolete catalog, or exposed to PNG import in the icon editor.
            if configured.count > 1 { return nil }
            if let package = configured.first {
                guard let source = composers.first(where: { $0.packageURL.path == package.path }) else {
                    return .unavailableComposer(package.path)
                }
                return .composer(source)
            }
            eligible = []
        }
        // Never choose an arbitrary target when several Composer documents match.
        if eligible.count == 1 { return .composer(eligible[0]) }
        if eligible.count > 1 { return nil }
        return candidates.sorted {
            if $0.pixels != $1.pixels { return $0.pixels > $1.pixels }
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.url.path < $1.url.path
        }.first.map { .raster($0.url.path) } ?? IconCandidate(url: generatedIcon, priority: 0).map { .raster($0.url.path) }
    }

    private struct IconCandidate {
        let url: URL
        let pixels: Int
        let priority: Int

        init?(url: URL, priority: Int) {
            // Asset entries are unordered and point sizes (e.g. 512@2x) are not pixels.
            // Decode off the main thread to reject missing/corrupt images as well.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width > 0, image.height > 0 else { return nil }
            self.url = url
            self.pixels = min(image.width, image.height)
            self.priority = priority
        }
    }
}

private struct ProjectAppIconIdentity: Hashable {
    let id: String
    let path: String
}

struct ProjectAppIconView<Placeholder: View>: View {
    let project: Project
    let size: CGFloat
    let cornerRadius: CGFloat
    let placeholder: () -> Placeholder

    @State private var icon: NSImage?
    @State private var displayedIconIdentity: ProjectAppIconIdentity
    @State private var loadRevision = 0

    private var iconIdentity: ProjectAppIconIdentity {
        ProjectAppIconIdentity(id: project.id, path: project.path)
    }

    init(
        project: Project,
        size: CGFloat,
        cornerRadius: CGFloat,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.project = project
        self.size = size
        self.cornerRadius = cornerRadius
        self.placeholder = placeholder
        _icon = State(initialValue: ProjectAppIconLoader.cachedImage(for: project.id))
        _displayedIconIdentity = State(initialValue: ProjectAppIconIdentity(id: project.id, path: project.path))
    }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                placeholder()
            }
        }
        .frame(width: size, height: size)
        .task(id: iconIdentity) {
            await loadIcon()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProjectAppIconLoader.didInvalidateNotification)) { notification in
            guard let invalidatedProjectId = notification.object as? String,
                  invalidatedProjectId == project.id else { return }
            // invalidate already reset the shared caches; multiple visible copies can reuse the fresh load.
            Task { await loadIcon() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard icon == nil else { return }
            Task { await loadIcon(forceRefresh: true) }
        }
    }

    @MainActor
    private func loadIcon(forceRefresh: Bool = false) async {
        loadRevision += 1
        let revision = loadRevision
        let identity = iconIdentity
        let pathChanged = displayedIconIdentity.id == identity.id && displayedIconIdentity.path != identity.path
        if displayedIconIdentity != identity {
            icon = nil
            displayedIconIdentity = identity
        }
        let shouldRefresh = forceRefresh || pathChanged
        if !shouldRefresh, let cached = ProjectAppIconLoader.cachedImage(for: project.id) {
            icon = cached
            return
        }

        let replacement: NSImage?
        if shouldRefresh {
            replacement = await ProjectAppIconLoader.refreshImage(
                for: project.id,
                projectPath: project.path
            )
        } else {
            replacement = await ProjectAppIconLoader.loadImage(
                for: project.id,
                projectPath: project.path
            )
        }
        // A temporarily missing/unfinished asset must not erase a working icon.
        guard revision == loadRevision, displayedIconIdentity == identity,
              !Task.isCancelled, let replacement else { return }
        icon = replacement
    }
}
