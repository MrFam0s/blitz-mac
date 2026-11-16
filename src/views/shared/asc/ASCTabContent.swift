// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

/// Wraps a tab's content with loading, error, and empty-app states.
struct ASCTabContent<Content: View>: View {
    var appState: AppState
    var asc: ASCManager
    var tab: AppTab
    var platform: ProjectPlatform = .iOS
    /// When true, tabs can render with only an ASC app loaded (no local project required).
    /// The synthesized App > Overview dashboard uses this so users can manage their
    /// ASC-only apps without first linking a local folder.
    var allowWithoutLocalProject: Bool = false
    @ViewBuilder var content: () -> Content

    private var isLoading: Bool {
        asc.isTabLoading(tab)
    }

    private var shouldRenderContentWhileLoading: Bool {
        asc.credentials != nil && asc.app != nil
    }

    private var hasSelectedProject: Bool {
        appState.activeProject != nil
    }

    private var gateIsOpen: Bool {
        hasSelectedProject || (allowWithoutLocalProject && asc.app != nil)
    }

    var body: some View {
        if !gateIsOpen {
            ASCNoProjectSelectedView()
        } else if isLoading && !shouldRenderContentWhileLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.tr("Wird geladen …"))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if asc.app == nil && asc.credentials != nil && !isLoading {
            VStack(spacing: 0) {
                HStack { ASCReleaseTargetPicker(asc: asc, tab: tab); Spacer() }.blitzToolbar()
                Divider()
                ProjectBundleIDSelectorView(
                appState: appState,
                asc: asc,
                tab: tab,
                platform: platform,
                title: L10n.tr("App-Store-Zuordnung"),
                standalone: true
                )
            }
        } else if let error = asc.tabError[tab], !asc.hasLoadedTabData(tab) {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                Button(L10n.tr("Erneut versuchen")) {
                    Task { await asc.refreshTabData(tab) }
                }
                .buttonStyle(.bordered)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                // Monetization already includes this picker in its version toolbar.
                if [.builds, .groups, .betaInfo, .feedback].contains(tab) {
                    HStack { ASCReleaseTargetPicker(asc: asc, tab: tab); Spacer() }.blitzToolbar()
                    Divider()
                }
                content()
            }
                .overlay(alignment: .topLeading) {
                    if let error = asc.tabError[tab], asc.hasLoadedTabData(tab) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Button(L10n.tr("Erneut versuchen")) {
                                Task { await asc.refreshTabData(tab) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                        .padding(12)
                    }
                }
        }
    }
}

struct ASCNoProjectSelectedView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text(L10n.tr("Wähle zuerst ein Projekt aus."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct ASCTabLoadingPlaceholder: View {
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(title)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct ASCTabRefreshButton: View {
    var asc: ASCManager
    var tab: AppTab
    var helpText: String = L10n.tr("Diese Rubrik aktualisieren")

    private var isRefreshing: Bool {
        asc.isTabLoading(tab)
    }

    private var refreshHelp: String {
        let date = tab == .app ? asc.overviewCacheDate : asc.tabLoadedAt[tab]
        guard let date else { return helpText }
        return L10n.tr("\(helpText) · Datenstand: \(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))")
    }

    var body: some View {
        Button {
            Task { await asc.refreshTabData(tab) }
        } label: {
            Group {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .disabled(isRefreshing)
        .accessibilityLabel(isRefreshing ? L10n.tr("Wird aktualisiert …") : helpText)
        .help(refreshHelp)
    }
}

/// Reusable info row for detail views.
struct InfoRow: View {
    var label: String
    var value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 150, alignment: .leading)
                Text(value)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(label).foregroundStyle(.secondary)
                Text(value)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(BlitzLayout.bodyFont)
        .padding(.vertical, 6)
    }
}

/// Formats an ISO 8601 date string for display.
func ascShortDate(_ iso: String) -> String {
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let f2 = ISO8601DateFormatter()
    if let d = f1.date(from: iso) ?? f2.date(from: iso) {
        return d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale))
    }
    return iso
}

/// Formats an ISO 8601 date string with time.
func ascLongDate(_ iso: String) -> String {
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let f2 = ISO8601DateFormatter()
    if let d = f1.date(from: iso) ?? f2.date(from: iso) {
        return d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))
    }
    return iso
}

/// Converts HTML to plain text using NSAttributedString, with regex fallback.
func htmlToPlainText(_ html: String) -> String {
    if let data = html.data(using: .utf8),
       let attributed = try? NSAttributedString(
           data: data,
           options: [
               .documentType: NSAttributedString.DocumentType.html,
               .characterEncoding: String.Encoding.utf8.rawValue,
           ],
           documentAttributes: nil
       ) {
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // Regex fallback: strip tags
    return html
        .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
