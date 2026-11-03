import SwiftUI

enum TestFlightPresentation {
    static func status(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Not available" }
        return value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func platform(_ value: String?) -> String {
        switch value {
        case "IOS": return "iOS"
        case "MAC_OS": return "macOS"
        case "TV_OS": return "tvOS"
        case "VISION_OS": return "visionOS"
        case "WATCH_OS": return "watchOS"
        case .some(let value) where !value.isEmpty: return value
        default: return "Platform unknown"
        }
    }

    static func buildLabel(_ build: ASCBuild) -> String {
        let version = build.preReleaseVersion?.attributes.version ?? "Version unknown"
        return "\(version) (\(build.attributes.version)) · \(platform(build.preReleaseVersion?.attributes.platform))"
    }

    static func expiration(_ build: ASCBuild, now: Date = Date()) -> String {
        if build.attributes.expired == true { return "Expired" }
        if let raw = build.attributes.expirationDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: raw)
            formatter.formatOptions = [.withInternetDateTime]
            if let date = fractional ?? formatter.date(from: raw) {
                return date <= now ? "Expired" : "Not expired"
            }
        }
        return build.attributes.expired == false ? "Not expired" : "Not available"
    }

    static func groupType(_ group: ASCBetaGroup) -> String {
        switch group.attributes.isInternalGroup {
        case true: "Internal"
        case false: "External"
        default: "Type unknown"
        }
    }
}

struct TestFlightDetailStatus: View {
    var isLoading: Bool
    var error: String?
    var hasData: Bool
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(hasData ? "Refreshing details…" : "Loading details…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error {
                Label(hasData ? "Refresh failed. Showing previously loaded details." : "Details could not be loaded.", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.medium)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button("Retry", action: retry).buttonStyle(.bordered).disabled(isLoading)
            }
            if !hasData && !isLoading && error == nil {
                Text("Details have not been loaded.").font(.callout).foregroundStyle(.secondary)
                Button("Load Details", action: retry).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TestFlightRefreshButton: View {
    var isRefreshing: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isRefreshing { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }.frame(width: 16, height: 16)
        }.buttonStyle(.borderless).disabled(isRefreshing)
    }
}

struct TestFlightTesterRow: View {
    var tester: ASCBetaTester

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let name = [tester.attributes.firstName, tester.attributes.lastName]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            Text(name.isEmpty ? (tester.attributes.email ?? tester.id) : name)
                .font(.callout.weight(.medium)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !name.isEmpty, let email = tester.attributes.email {
                Text(email).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text("Invitation: \(TestFlightPresentation.status(tester.attributes.inviteType)) · State: \(TestFlightPresentation.status(tester.attributes.state))")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}
