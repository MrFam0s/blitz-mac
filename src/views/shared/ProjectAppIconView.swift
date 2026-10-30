import AppKit
import ImageIO
import SwiftUI

private enum ProjectAppIconLookupState {
    case unresolved
    case resolved(String)
    case missing
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
        guard let path = await loadPath(for: projectId, projectPath: projectPath) else { return nil }
        return path.hasSuffix("assets/AppIcon/icon_1024.png") ? "1024px" : "Configured"
    }

    static func refreshImage(for projectId: String, projectPath: String) async -> NSImage? {
        resetCache(for: projectId)
        return await loadImage(for: projectId, projectPath: projectPath)
    }

    static func invalidate(for projectId: String) {
        resetCache(for: projectId)
        NotificationCenter.default.post(name: didInvalidateNotification, object: projectId)
    }

    static func loadPath(for projectId: String, projectPath: String) async -> String? {
        let state = cacheState(for: projectId)
        switch state.path {
        case .resolved(let path):
            return path
        case .missing:
            break
        case .unresolved:
            break
        }

        let path = await Task.detached(priority: .utility) {
            findIconPath(projectPath: projectPath)
        }.value

        return cachePath(path, for: projectId, revision: state.revision) ? path : nil
    }

    private static func cacheState(for projectId: String) -> (path: ProjectAppIconLookupState, revision: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (pathCache[projectId] ?? .unresolved, cacheRevisions[projectId] ?? 0)
    }

    private static func cachePath(_ path: String?, for projectId: String, revision: Int) -> Bool {
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

    private static func findIconPath(projectPath: String) -> String? {
        let fm = FileManager.default
        let projectDir = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath()
        var candidates: [IconCandidate] = []
        let generatedIcon = projectDir.appendingPathComponent("assets/AppIcon/icon_1024.png")
        if let candidate = IconCandidate(url: generatedIcon, priority: 2) {
            candidates.append(candidate)
        }
        guard let enumerator = fm.enumerator(
            at: projectDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return candidates.first?.url.path
        }

        while let entry = enumerator.nextObject() as? URL {
            let name = entry.lastPathComponent

            if skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
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
        return candidates.sorted {
            if $0.pixels != $1.pixels { return $0.pixels > $1.pixels }
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.url.path < $1.url.path
        }.first?.url.path
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
