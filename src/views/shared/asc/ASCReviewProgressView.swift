// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

extension ASCReviewProgress {
    @MainActor init(asc: ASCManager, version: ASCAppStoreVersion?) {
        self.init(version: version, submissions: asc.reviewSubmissions,
                  itemsBySubmissionID: asc.reviewSubmissionItemsBySubmissionId,
                  matchedFeedback: version.map { asc.feedbackSelection(for: $0).matched } ?? [],
                  isComplete: asc.reviewSubmissionDataComplete)
    }

    var title: String {
        switch phase {
        case .draft: L10n.tr("Noch nicht eingereicht")
        case .needsResolution: L10n.tr("Probleme vor erneuter Einreichung klären")
        case .readyToSubmit: L10n.tr("Bereit zur Prüfung – noch nicht abgesendet")
        case .readyToResubmit: L10n.tr("Erneute Einreichung noch nicht abgesendet")
        case .waitingForReview: L10n.tr("Einreichung bestätigt – wartet auf Prüfung")
        case .inReview: L10n.tr("Apple prüft die Einreichung")
        case .accepted: L10n.tr("Prüfung abgeschlossen")
        case .unavailable: L10n.tr("Prüfstatus nicht eindeutig bestätigt")
        }
    }
    var guidance: String {
        switch phase {
        case .draft: L10n.tr("Prüfe Version, Build und Store-Angaben. Erst die Bestätigung in der Vorschau sendet die Einreichung an Apple.")
        case .needsResolution:
            L10n.tr("Prüfe Apples Hinweise und behebe die offenen Punkte. Bestätige danach die geklärten Probleme und sende die bestehende Einreichung erneut ab. Eine Antwort allein führt diesen Schritt nicht aus.")
        case .readyToSubmit:
            L10n.tr("Die Version ist für die Prüfung vorbereitet. Erst das Absenden startet die Einreichung bei Apple.")
        case .readyToResubmit:
            L10n.tr("Die bearbeiteten Elemente sind vorbereitet. Sende jetzt dieselbe Einreichung erneut zur App-Prüfung; ein neuer Entwurf ist dafür nicht erforderlich.")
        case .waitingForReview, .inReview:
            L10n.tr("Die Einreichung ist bei Apple eingegangen. Eine weitere Einreichung ist derzeit nicht erforderlich.")
        case .accepted:
            L10n.tr("Beachte den Versionsstatus für die Veröffentlichung. Frühere Rückfragen bleiben im Verlauf sichtbar.")
        case .unavailable where statusConflict:
            L10n.tr("Apples Versionsstatus und der Status der zugehörigen Einreichung widersprechen sich. Aktualisiere beide, bevor du daraus den nächsten Schritt ableitest.")
        case .unavailable:
            L10n.tr("Aktualisiere den Prüfstatus oder prüfe den bestehenden Vorgang in App Store Connect, bevor du erneut einreichst.")
        }
    }
    var previewTitle: String {
        isRecovery ? L10n.tr("Erneute Einreichung prüfen") : L10n.tr("Einreichung prüfen")
    }
    var tone: Color {
        switch phase {
        case .needsResolution: .orange
        case .readyToSubmit, .readyToResubmit, .draft: .secondary
        case .waitingForReview, .inReview: .blue
        case .accepted: .green
        case .unavailable: .secondary
        }
    }
    var symbol: String {
        switch phase {
        case .needsResolution: "exclamationmark.circle"
        case .readyToSubmit, .readyToResubmit, .draft: "paperplane"
        case .waitingForReview: "clock"
        case .inReview: "eye"
        case .accepted: "checkmark.circle"
        case .unavailable: "questionmark.circle"
        }
    }
}

struct ASCReviewProgressView: View {
    let progress: ASCReviewProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(progress.title, systemImage: progress.symbol)
                .font(BlitzLayout.sectionTitle)
                .foregroundStyle(progress.tone)
                .fixedSize(horizontal: false, vertical: true)
            Text(progress.guidance)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = progress.latestMessage, let date = message.createdAt {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text(message.sender == .developer
                         ? L10n.tr("Letzte Nachricht: Deine Antwort vom \(ascShortDate(date))")
                         : message.sender == .apple
                         ? L10n.tr("Letzte Nachricht: Apple vom \(ascShortDate(date))")
                         : L10n.tr("Letzte Nachricht vom \(ascShortDate(date))"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BlitzLayout.cardInset)
        .background(progress.tone.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
