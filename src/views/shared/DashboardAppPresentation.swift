import SwiftUI

struct DashboardEntrySize {
    static let iconRange = 40.0...72.0
    static let defaultIconSize = 56.0
    static let step = 4.0

    let icon: CGFloat

    init(_ stored: Double) {
        let value = stored.isFinite ? stored : Self.defaultIconSize
        icon = min(max(value, Self.iconRange.lowerBound), Self.iconRange.upperBound)
    }

    var cornerRadius: CGFloat { icon * 0.22 }
    var minimumColumnWidth: CGFloat { 254 + (icon - Self.iconRange.lowerBound) * 1.25 }
    var nameSize: CGFloat { 13 + (icon - Self.iconRange.lowerBound) / 8 }
    var captionSize: CGFloat { nameSize - 2 }
}

extension DashboardAppSortField {
    var title: String {
        switch self {
        case .name: return L10n.tr("Name")
        case .status: return L10n.tr("Status")
        case .modified: return L10n.tr("Änderungsdatum")
        }
    }
}

struct DashboardSortControl: View {
    @Binding var field: DashboardAppSortField
    @Binding var direction: DashboardAppSortDirection

    var body: some View {
        HStack(spacing: 4) {
            Picker(L10n.tr("Sortieren nach"), selection: Binding(
                get: { field },
                set: { newField in
                    guard newField != field else { return }
                    field = newField
                    direction = newField == .modified ? .descending : .ascending
                }
            )) {
                ForEach(DashboardAppSortField.allCases, id: \.self) { option in
                    Text(option == .modified ? L10n.tr("Datum") : option.title)
                        .accessibilityLabel(option.title)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help(L10n.tr("Sortieren nach"))

            Button {
                direction = direction == .ascending ? .descending : .ascending
            } label: {
                Image(systemName: direction == .ascending ? "arrow.up" : "arrow.down")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.tr("Sortierrichtung umkehren"))
            .accessibilityValue(directionTitle)
            .help(L10n.tr("\(directionTitle) · Sortierrichtung umkehren"))
        }
        .fixedSize()
    }

    private var directionTitle: String {
        switch (field, direction) {
        case (.modified, .ascending): return L10n.tr("Älteste zuerst")
        case (.modified, .descending): return L10n.tr("Neueste zuerst")
        case (_, .ascending): return L10n.tr("Aufsteigend")
        case (_, .descending): return L10n.tr("Absteigend")
        }
    }
}

extension DashboardAppStatus {
    var title: String {
        switch self {
        case .rejected: return L10n.tr("Abgelehnt")
        case .pendingReview: return L10n.tr("In Prüfung")
        case .live: return L10n.tr("Im App Store")
        case .unavailable: return L10n.tr("Nicht im App Store")
        case .draft: return L10n.tr("Nicht veröffentlicht")
        case .localOnly: return L10n.tr("Nur lokal")
        case .unknown: return L10n.tr("Status unbekannt")
        }
    }

    private var markerColor: Color {
        switch self {
        case .live: return .green
        case .pendingReview: return .orange
        case .rejected: return .red
        case .draft: return .yellow
        case .unavailable, .localOnly, .unknown: return .gray
        }
    }

    var markedTitle: Text {
        let label = Text(verbatim: title).foregroundColor(.secondary)
        let marker = Text(Image(systemName: self == .localOnly ? "circle" : "circle.fill"))
            .foregroundColor(markerColor)
        return Text("\(label)\u{202F}\(marker)")
    }
}

extension DashboardPlatformGroup {
    var title: String {
        switch self {
        case .iOS: "iOS"
        case .macOS: "macOS"
        case .shared: "macOS + iOS"
        case .other: L10n.tr("Weitere Plattformen")
        }
    }
}

enum DashboardPlatformPresentation {
    static func orderedCodes(_ codes: [String]?) -> [String] {
        Array(Set(codes ?? [])).sorted {
            let order = ["MAC_OS", "IOS", "TV_OS", "VISION_OS", "UNKNOWN"]
            let lhs = order.firstIndex(of: $0) ?? order.count
            let rhs = order.firstIndex(of: $1) ?? order.count
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
    }

    static func name(_ code: String) -> String {
        switch code {
        case "MAC_OS": return "macOS"
        case "IOS": return "iOS"
        case "TV_OS": return "tvOS"
        case "VISION_OS": return "visionOS"
        case "UNKNOWN": return L10n.tr("Unbekannt")
        default: return code
        }
    }

    static func title(_ codes: [String]?) -> String {
        let values = orderedCodes(codes)
        return values.isEmpty ? L10n.tr("Plattform unbekannt") : values.map(name).joined(separator: " + ")
    }
}

extension DashboardAppRow {
    func dashboardStatuses(primary: DashboardAppStatus) -> [DashboardAppStatus] {
        // A version can be in review or rejected while its listing is off sale.
        if status?.isUnavailableOnStore == true && (primary == .pendingReview || primary == .rejected) {
            return [primary, .unavailable]
        }
        return [primary]
    }

    func dashboardPlatformHelp(includeStatuses: Bool) -> String {
        let title = DashboardPlatformPresentation.title(platformCodes)
        var lines = [title]
        if source == .asc, let platformCodes, platformCodes.contains("MAC_OS"), platformCodes.contains("IOS") {
            lines.append(L10n.tr("Gemeinsamer App-Store-Eintrag für macOS und iOS"))
        } else if source == .localOnly {
            lines.append(L10n.tr("Plattform des lokalen Projektziels"))
        }
        if includeStatuses, let summaries = status?.localizedPlatformSummaries {
            lines += summaries.keys.sorted().map {
                "\(DashboardPlatformPresentation.name($0)): \(summaries[$0] ?? "")"
            }
        }
        return lines.joined(separator: "\n")
    }

    var dashboardDateHelp: String {
        if let lastChangedAt {
            return L10n.tr("Änderung von Blitz erkannt: \(lastChangedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))")
        }
        if let latestVersionCreatedAt {
            return L10n.tr("Neuester Versionsentwurf erstellt: \(latestVersionCreatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))). Apple liefert kein allgemeines Änderungsdatum.")
        }
        return L10n.tr("Kein Änderungsdatum bekannt")
    }
}

struct DashboardDateCaption: View {
    let row: DashboardAppRow
    let font: Font

    var body: some View {
        Text(caption)
            .font(font)
            .foregroundStyle(.secondary)
            .help(row.dashboardDateHelp)
    }

    private var caption: String {
        guard let date = row.sortDate else { return L10n.tr("Datum unbekannt") }
        let dateText = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale))
        return row.lastChangedAt != nil ? L10n.tr("Geändert am \(dateText)") : L10n.tr("Version vom \(dateText)")
    }
}
