import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AssetsView: View {
    var appState: AppState

    @State private var sourceIcon: NSImage?
    @State private var sourceIconName: String?
    @State private var generatedIcons: [Int: NSImage] = [:]
    @State private var isDropTargeted = false
    @State private var importError: String?
    @State private var isGenerating = false
    @State private var iconRevision = UUID()
    @State private var showColorGenerator = false
    @State private var iconColor: Color = .blue

    private var projectId: String? { appState.activeProjectId }

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
        HStack(spacing: 0) {
            sourcePanel
                .frame(width: 220)
            Divider()
            iconGridPanel
        }
        .task(id: projectId) { await loadExistingIcons() }
        .alert("Import Error", isPresented: Binding(
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

    private var sourcePanel: some View {
        VStack(spacing: 16) {
            Text("Source Icon")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            dropZone

            Button {
                openIconPicker()
            } label: {
                Label("Choose File", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Divider()

            Button {
                showColorGenerator = true
            } label: {
                Label("Generate from Color", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Spacer()

            if sourceIcon != nil {
                Text("1024 \u{00d7} 1024")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let name = sourceIconName {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(16)
        .background(.background.secondary)
    }

    private var dropZone: some View {
        ZStack {
            if let icon = sourceIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .padding(8)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Drop 1024\u{00d7}1024\nicon here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.1) : Color(.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: sourceIcon == nil ? [6, 4] : [])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    // MARK: - Icon Grid (Right)

    private var iconGridPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BlitzLayout.sectionSpacing) {
                Text("App Icon")
                    .font(BlitzLayout.pageTitle)

                if isGenerating {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating icons\u{2026}")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

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
            .blitzPagePadding()
        }
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
        generatedIcons = [:]
        isGenerating = false
        guard let path = await ProjectAppIconLoader.loadPath(for: project.id, projectPath: project.path),
              let image = await ProjectAppIconLoader.loadImage(for: project.id, projectPath: project.path),
              !Task.isCancelled, appState.activeProjectId == project.id,
              iconRevision == revision else { return }
        sourceIcon = image
        sourceIconName = URL(fileURLWithPath: path).lastPathComponent
        generateAllSizes(from: image, saveToDisk: false)
    }

    // MARK: - Actions

    private func openIconPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a 1024 \u{00d7} 1024 app icon"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSourceIcon(from: url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                loadSourceIcon(from: url)
            }
        }
    }

    private func loadSourceIcon(from url: URL) {
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
            let fm = FileManager.default

            if saveToDisk, let basePath {
                try? fm.createDirectory(atPath: basePath, withIntermediateDirectories: true)
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
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                }
            }

            // Also update xcassets icon if present
            if saveToDisk, let projDir {
                Self.updateXcassetsIcon(source: source, projectDir: projDir)
            }

            let finalIcons = icons
            await MainActor.run {
                guard appState.activeProjectId == pid, iconRevision == revision else { return }
                generatedIcons = finalIcons
                isGenerating = false
                if let pid {
                    appState.ascManager.checkAppIcon(projectId: pid)
                }
            }
        }
    }

    /// Copies the 1024×1024 source into the xcassets AppIcon.appiconset if one exists.
    nonisolated private static func updateXcassetsIcon(source: NSImage, projectDir: String) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: projectDir) else { return }
        while let file = enumerator.nextObject() as? String {
            guard file.hasSuffix("AppIcon.appiconset/Contents.json") else { continue }
            let contentsPath = "\(projectDir)/\(file)"
            guard let data = fm.contents(atPath: contentsPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let images = json["images"] as? [[String: Any]] else { continue }
            for entry in images {
                if let filename = entry["filename"] as? String {
                    let iconDir = (contentsPath as NSString).deletingLastPathComponent
                    let iconPath = "\(iconDir)/\(filename)"
                    if let tiff = source.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiff),
                       let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: iconPath))
                    }
                    return
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
