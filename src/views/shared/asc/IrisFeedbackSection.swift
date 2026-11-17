// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

/// Cached conversations remain readable when refresh or authentication fails.
/// Unassigned app-level threads are deliberately separate from version evidence.
struct IrisFeedbackSection: View {
    var matched: [IrisFeedbackCycle]
    var unassigned: [IrisFeedbackCycle]
    var isLoading: Bool
    var error: String?
    var sessionState: ASCManager.IrisSessionState
    var hasSuccessfulFetch: Bool
    var appStoreURL: URL?
    var reload: () -> Void
    var signIn: () -> Void

    private var hasMessages: Bool { !matched.isEmpty || !unassigned.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("Kommunikation mit Apple"))
                .font(BlitzLayout.sectionTitle)

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("Rückmeldung wird geladen …"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !matched.isEmpty {
                feedbackCyclesView(matched)
            }

            if !unassigned.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("Nachrichten ohne eindeutige Versionszuordnung"))
                        .font(.callout.weight(.semibold))
                    Text(L10n.tr("Diese Nachrichten gehören zur App. Sie lassen sich keiner Version oder Plattform eindeutig zuordnen."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    feedbackCyclesView(unassigned)
                }
            }

            // Authentication and refresh state are independent of cached content.
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch sessionState {
            case .noSession, .unknown:
                signInCard(
                    icon: "person.badge.key",
                    message: L10n.tr("Melde dich mit deinem Apple-Account an, um die Nachrichten zu aktualisieren."),
                    buttonTitle: L10n.tr("Anmelden"),
                    color: .secondary
                )
            case .expired:
                signInCard(
                    icon: "clock.badge.exclamationmark",
                    message: L10n.tr("Die Apple-Anmeldung ist abgelaufen."),
                    buttonTitle: L10n.tr("Erneut anmelden"),
                    color: .orange
                )
            case .valid:
                if !hasMessages && !isLoading && error == nil {
                    Text(hasSuccessfulFetch
                         ? L10n.tr("Beim letzten Abruf wurden keine passenden Nachrichten geladen. Den vollständigen Verlauf findest du in App Store Connect.")
                         : L10n.tr("Für diese Ansicht sind noch keine Nachrichten geladen. Aktualisiere den Verlauf oder öffne App Store Connect."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            BlitzFlowLayout(horizontalSpacing: 12, verticalSpacing: 8) {
                if case .valid = sessionState {
                    Button(L10n.tr("Nachrichten aktualisieren"), action: reload)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isLoading)
                }
                if let appStoreURL {
                    Link(L10n.tr("In App Store Connect öffnen"), destination: appStoreURL)
                        .font(.callout)
                }
            }
        }
    }

    private func signInCard(icon: String, message: String, buttonTitle: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: icon)
                .font(.callout)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Button(buttonTitle, action: signIn)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(BlitzLayout.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func feedbackCyclesView(_ cycles: [IrisFeedbackCycle]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(cycles) { cycle in
                VStack(alignment: .leading, spacing: 8) {
                    BlitzFlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
                        if let submissionId = cycle.submissionId, !submissionId.isEmpty {
                            Text(submissionId)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        } else {
                            Text(L10n.tr("Archivierter Verlauf"))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(ascLongDate(cycle.occurredAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    ForEach(cycle.reasons) { reason in
                        reasonCard(reason)
                    }
                    ForEach(cycle.messages) { message in
                        messageCard(message)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.tertiary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func reasonCard(_ reason: IrisFeedbackCycle.Reason) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !reason.section.isEmpty {
                Text(reason.section)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
            }
            if !reason.description.isEmpty {
                Text(reason.description)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if !reason.code.isEmpty {
                Text("Code: \(reason.code)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func messageCard(_ message: IrisFeedbackCycle.Message) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            BlitzFlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
                Text(senderLabel(message.sender))
                    .font(.caption.weight(.semibold))
                if let date = message.createdAt {
                    Text(ascLongDate(date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(message.body.isEmpty ? L10n.tr("Kein Nachrichtentext verfügbar.") : message.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func senderLabel(_ sender: IrisFeedbackCycle.Message.Sender?) -> String {
        switch sender ?? .unknown {
        case .apple: return L10n.tr("Apple")
        case .developer: return L10n.tr("Deine Antwort")
        case .unknown: return L10n.tr("Nachricht")
        }
    }
}
