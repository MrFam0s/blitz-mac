import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AssetsView: View {
    var appState: AppState

    @State private var sourceIcon: NSImage?
    @State private var sourceIconName: String?
    @State private var composerPackagePath: String?
    @State private var isLoadingSource = true
    @State private var isPreviewUnavailable = false
    @State private var generatedIcons: [Int: NSImage] = [:]
    @State private var isDropTargeted = false
    @State private var importError: String?
    @State private var isGenerating = false
    @State private var iconRevision = UUID()
    @State private var showColorGenerator = false
    @State private var iconColor: Color = .blue

    private var projectId: String? { appState.activeProjectId }

    private var projectIdentity: String? {
        appState.activeProject.map { "\($0.id)\n\($0.path)" }
    }

    private var canImportIcon: Bool {
        !isLoadingSource && !isGenerating && composerPackagePath == nil
    }

    private var iconBasePath: String? {
        guard let projectId else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.blitz/projects/\(projectId)/assets/AppIcon"
    }

    private let iconSizes: [(String, Int)] = [
        ("1024pt", 1024),
        ("120pt", 120),
        ("87pt", 87),
        ("80pt", 80),
        ("60pt", 60),
        ("58pt", 58),
        ("40pt", 40),
        ("29pt", 29),
        ("20pt", 20),
    ]

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 620 {
                ScrollView {
                    VStack(spacing: 0) {
                        compactSourcePanel
                        Divider()
                        iconGridContent
                    }
                }
            } else {
                HStack(spacing: 0) {
                    sourcePanel
                        .frame(width: 220)
                    Divider()
                    ScrollView { iconGridContent }
                }
            }
        }
        .task(id: projectIdentity) { await loadExistingIcons() }
        .onReceive(NotificationCenter.default.publisher(for: ProjectAppIconLoader.didInvalidateNotification)) { notification in
            guard let invalidatedProjectId = notification.object as? String,
                  invalidatedProjectId == projectId else { return }
            Task { await loadExistingIcons() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard let projectId, composerPackagePath != nil,
                  !isLoadingSource, !isGenerating else { return }
            // Changes made in Icon Composer must be reflected when returning to Blitz.
            ProjectAppIconLoader.invalidate(for: projectId)
        }
        .alert("App Icon", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .sheet(isPresented: $showColorGenerator) {
            colorGeneratorSheet
        }
    }

    // MARK: - Source Panel (Left)

    private var compactSourcePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source Icon")
                .font(BlitzLayout.pageTitle)
            HStack(alignment: .top, spacing: 16) {
                dropZone(height: 128)
                    .frame(width: 128)
                VStack(alignment: .leading, spacing: 8) {
                    sourceActions
                    sourceCaption
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .blitzPagePadding()
        .background(.background.secondary)
    }

    private var sourcePanel: some View {
        VStack(spacing: 16) {
            Text("Source Icon")
                .font(BlitzLayout.pageTitle)
                .frame(maxWidth: .infinity, alignment: .leading)

            dropZone(height: 180)
            sourceActions
            Spacer()
            sourceCaption
        }
        .padding(BlitzLayout.pageInset)
        .background(.background.secondary)
    }

    private var sourceActions: some View {
        VStack(spacing: 8) {
            if composerPackagePath != nil {
                Button {
                    openIconComposer()
                } label: {
                    Label("Open in Icon Composer", systemImage: "arrow.up.forward.app")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Text("This project uses an Icon Composer document. Edit it in Icon Composer to preserve its layers and appearances.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    openIconPicker()
                } label: {
                    Label("Choose File", systemImage: "plus.circle")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    showColorGenerator = true
                } label: {
                    Label("Generate from Color", systemImage: "wand.and.stars")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .font(BlitzLayout.toolbarFont)
        .controlSize(.small)
        .disabled(isLoadingSource || isGenerating)
    }

    private var sourceCaption: some View {
        VStack(alignment: .leading, spacing: 4) {
            if sourceIcon != nil {
                Text("1024 \u{00d7} 1024")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let name = sourceIconName {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(name)
            }
        }
    }

    private func dropZone(height: CGFloat) -> some View {
        ZStack {
            if let icon = sourceIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .padding(8)
            } else if isLoadingSource {
                ProgressView("Loading preview\u{2026}")
                    .font(.caption)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: composerPackagePath == nil ? "arrow.down.doc" : "app.dashed")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(composerPackagePath == nil ? "Drop 1024\u{00d7}1024\nicon here" : "Preview unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isDropTargeted && canImportIcon ? Color.accentColor.opacity(0.1) : Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isDropTargeted && canImportIcon ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: composerPackagePath == nil && sourceIcon == nil ? [6, 4] : [])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard canImportIcon else { return false }
            handleDrop(providers)
            return true
        }
    }

    // MARK: - Icon Grid (Right)

    private var iconGridContent: some View {
        VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
            Text("App Icon")
                .font(BlitzLayout.pageTitle)

            if isLoadingSource || isGenerating {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(isLoadingSource ? "Loading preview\u{2026}" : "Generating previews\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if isPreviewUnavailable {
                Label("This project uses an Icon Composer document, but its preview could not be loaded. Open it in Icon Composer to check the document and its layers.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(iconSizes, id: \.1) { label, size in
                        VStack(spacing: 6) {
                            iconImage(size: size)
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .blitzPagePadding()
    }

    @ViewBuilder
    private func iconImage(size: Int) -> some View {
        if let image = generatedIcons[size] {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            placeholderIcon
        }
    }

    private var placeholderIcon: some View {
        Image(systemName: "app.fill")
            .font(.system(size: 40))
            .foregroundStyle(.quaternary)
            .frame(width: 80, height: 80)
            .background(.background.secondary)
    }

    // MARK: - Load Existing Icons

    @MainActor
    private func loadExistingIcons() async {
        guard let project = appState.activeProject else { return }
        let revision = UUID()
        iconRevision = revision
        sourceIcon = nil
        sourceIconName = nil
        composerPackagePath = nil
        isLoadingSource = true
        isPreviewUnavailable = false
        generatedIcons = [:]
        isGenerating = false
        showColorGenerator = false
        let composerPath = await ProjectAppIconLoader.composerPackagePath(for: project.id, projectPath: project.path)
        guard !Task.isCancelled, appState.activeProjectId == project.id,
              appState.activeProject?.path == project.path, iconRevision == revision else { return }
        composerPackagePath = composerPath
        sourceIconName = composerPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let path = await ProjectAppIconLoader.loadPath(for: project.id, projectPath: project.path)
        let image: NSImage?
        if path != nil {
            image = await ProjectAppIconLoader.loadImage(for: project.id, projectPath: project.path)
        } else {
            image = nil
        }
        guard !Task.isCancelled, appState.activeProjectId == project.id,
              appState.activeProject?.path == project.path, iconRevision == revision else { return }
        isLoadingSource = false
        guard let path, let image else {
            isPreviewUnavailable = composerPath != nil
            return
        }
        sourceIcon = image
        if composerPath == nil { sourceIconName = URL(fileURLWithPath: path).lastPathComponent }
        generateAllSizes(from: image, saveToDisk: false)
    }

    // MARK: - Actions

    private func openIconComposer() {
        guard let composerPackagePath else { return }
        let bundledComposer = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/Icon Composer.app")
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.IconComposer")
                ?? (FileManager.default.fileExists(atPath: bundledComposer.path) ? bundledComposer : nil) else {
            importError = "Icon Composer could not be found. Open this document with Icon Composer from your Xcode installation."
            return
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: composerPackagePath)], withApplicationAt: applicationURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                importError = "Could not open Icon Composer: \(error.localizedDescription)"
            }
        }
    }

    private func openIconPicker() {
        guard canImportIcon else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a 1024 \u{00d7} 1024 app icon"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSourceIcon(from: url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        guard canImportIcon, let provider = providers.first else { return }
        let identity = projectIdentity
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                guard projectIdentity == identity else { return }
                loadSourceIcon(from: url)
            }
        }
    }

    private func loadSourceIcon(from url: URL) {
        guard canImportIcon else { return }
        guard let image = NSImage(contentsOf: url) else {
            importError = "Could not load image."
            return
        }

        // Validate 1024×1024 pixel dimensions
        var w = 0, h = 0
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            w = rep.pixelsWide
            h = rep.pixelsHigh
        } else if let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) {
            w = bitmap.pixelsWide
            h = bitmap.pixelsHigh
        }

        guard w == 1024 && h == 1024 else {
            importError = "Icon must be 1024 \u{00d7} 1024 pixels. Got \(w) \u{00d7} \(h)."
            return
        }

        sourceIcon = image
        sourceIconName = url.lastPathComponent
        importError = nil
        generateAllSizes(from: image, saveToDisk: true)
    }

    // MARK: - Resize & Save

    private func generateAllSizes(from source: NSImage, saveToDisk: Bool) {
        guard !saveToDisk || canImportIcon else { return }
        guard let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let revision = UUID()
        iconRevision = revision

        let basePath = iconBasePath
        let sizes = iconSizes
        let pid = projectId
        let projDir: String? = pid.map { pid in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return "\(home)/.blitz/projects/\(pid)"
        }

        isGenerating = true

        Task.detached {
            var icons: [Int: NSImage] = [:]
            var saveError: String?
            let fm = FileManager.default

            if saveToDisk, let basePath {
                do {
                    try fm.createDirectory(atPath: basePath, withIntermediateDirectories: true)
                } catch {
                    saveError = error.localizedDescription
                }
            }

            for (_, size) in sizes {
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                guard let ctx = CGContext(
                    data: nil, width: size, height: size,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { continue }

                ctx.interpolationQuality = .high
                ctx.draw(cgSource, in: CGRect(x: 0, y: 0, width: size, height: size))

                guard let resized = ctx.makeImage() else { continue }
                let nsImage = NSImage(cgImage: resized, size: NSSize(width: size, height: size))
                icons[size] = nsImage

                if saveToDisk, let basePath {
                    let bitmap = NSBitmapImageRep(cgImage: resized)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        let path = "\(basePath)/icon_\(size).png"
                        do {
                            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                        } catch {
                            saveError = saveError ?? error.localizedDescription
                        }
                    }
                }
            }

            // Also update xcassets icon if present
            if saveToDisk, let projDir {
                do {
                    try ProjectAppIconCatalogWriter.write(source: cgSource, projectPath: projDir)
                } catch {
                    saveError = saveError ?? error.localizedDescription
                }
            }

            let finalIcons = icons
            let finalError = saveError
            await MainActor.run {
                guard appState.activeProjectId == pid, iconRevision == revision else { return }
                generatedIcons = finalIcons
                isGenerating = false
                if let finalError { importError = "Could not save app icons: \(finalError)" }
                if saveToDisk, let pid {
                    appState.ascManager.checkAppIcon(projectId: pid)
                }
            }
        }
    }

    // MARK: - Color Generator Sheet

    private var colorGeneratorSheet: some View {
        VStack(spacing: 20) {
            Text("Generate App Icon")
                .font(.title3.weight(.semibold))

            ColorPicker("Icon Color", selection: $iconColor, supportsOpacity: false)
                .frame(maxWidth: 200)

            RoundedRectangle(cornerRadius: 22)
                .fill(iconColor)
                .frame(width: 100, height: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                )

            Text("Generates solid-color PNG icons for all required sizes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { showColorGenerator = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Generate") {
                    generateColorIcon()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating)
                .keyboardShortcut(.defaultAction)
            }

            if isGenerating {
                ProgressView("Generating\u{2026}")
            }
        }
        .padding(24)
        .frame(width: 320)
    }

    private func generateColorIcon() {
        guard canImportIcon else { return }
        let size = NSSize(width: 1024, height: 1024)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(iconColor).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        sourceIcon = image
        sourceIconName = "Generated"
        showColorGenerator = false
        generateAllSizes(from: image, saveToDisk: true)
    }
}
