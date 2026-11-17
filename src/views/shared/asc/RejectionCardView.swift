import SwiftUI

/// Shared rejection feedback card used by both ASCOverview and ReviewView.
struct RejectionCardView<Footer: View>: View {
    var asc: ASCManager
    var version: ASCAppStoreVersion
    @ViewBuilder var footer: () -> Footer
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Clickable header region — toggles expansion
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    reviewHistory
                    reviewItems
                    submittedReviewInfo
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Collapsible content
            if expanded {
                appleFeedbackSection
                footer()
            }
        }
        .padding(BlitzLayout.cardInset)
        .background(Color.red.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.red.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("Version \(version.attributes.versionString) abgelehnt"))
                    .font(BlitzLayout.sectionTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = version.attributes.createdDate {
                    Text(L10n.tr("Eingereicht am \(ascShortDate(date))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Review History

    @ViewBuilder
    private var reviewHistory: some View {
        if !asc.reviewSubmissions.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("Prüfungsverlauf"))
                    .font(BlitzLayout.sectionTitle)

                ForEach(asc.reviewSubmissions.prefix(5)) { submission in
                    BlitzFlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(submissionStateColor(submission.attributes.state ?? ""))
                                .frame(width: 8, height: 8)
                            Text(submissionStateLabel(submission.attributes.state ?? ""))
                                .font(.callout)
                        }
                        if let date = submission.attributes.submittedDate {
                            Text(ascShortDate(date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Review Items

    @ViewBuilder
    private var reviewItems: some View {
        let submissionItems = asc.latestSubmissionItems(forVersionId: version.id)

        if !submissionItems.isEmpty {
            let rejected = submissionItems.filter { $0.attributes.state == "REJECTED" }
            let accepted = submissionItems.filter { $0.attributes.state == "ACCEPTED" || $0.attributes.state == "APPROVED" }

            if !rejected.isEmpty || !accepted.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("Prüfungsbestandteile"))
                        .font(BlitzLayout.sectionTitle)

                    ForEach(submissionItems) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.attributes.state == "REJECTED" ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(item.attributes.state == "REJECTED" ? .red : .green)
                                .font(.caption)
                            Text(BlitzDisplayText.status(item.attributes.state ?? ""))
                                .font(.callout)
                            if item.attributes.resolved == true {
                                Text(L10n.tr("Geklärt"))
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.15))
                                    .foregroundStyle(.green)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Submitted Review Info

    @ViewBuilder
    private var submittedReviewInfo: some View {
        if let rd = asc.reviewDetail {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("Eingereichte Prüfungsangaben"))
                    .font(BlitzLayout.sectionTitle)

                if let notes = rd.attributes.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("Deine Hinweise an Apple"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(notes)
                            .font(.callout)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background.tertiary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                if rd.attributes.demoAccountRequired == true {
                    HStack(spacing: 6) {
                        Image(systemName: "person.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(L10n.tr("Demokonto: \(rd.attributes.demoAccountName ?? "—")"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let contact = rd.attributes.contactEmail {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(L10n.tr("Kontakt: \(rd.attributes.contactFirstName ?? "") \(rd.attributes.contactLastName ?? "") (\(contact))"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Review conversation

    private var appleFeedbackSection: some View {
        let selection = asc.feedbackSelection(for: version)
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            IrisFeedbackSection(
                matched: selection.matched,
                unassigned: selection.unassigned,
                isLoading: asc.isLoadingIrisFeedback,
                error: asc.irisFeedbackError,
                sessionState: asc.irisSessionState,
                hasSuccessfulFetch: asc.app.map { asc.irisLastFetchedAtByAppId[$0.id] != nil } ?? false,
                appStoreURL: asc.app.flatMap {
                    URL(string: "https://appstoreconnect.apple.com/apps/\($0.id)/distribution/reviewsubmissions")
                },
                reload: { Task { await asc.fetchRejectionFeedback(force: true) } },
                signIn: { asc.showAppleIDLogin = true }
            )
        }
    }

    // MARK: - Submission State Helpers

    private func submissionStateColor(_ state: String) -> Color {
        switch state {
        case "COMPLETE": return .green
        case "IN_PROGRESS", "WAITING_FOR_REVIEW": return .blue
        case "CANCELING": return .orange
        default: return .secondary
        }
    }

    private func submissionStateLabel(_ state: String) -> String {
        switch state {
        case "COMPLETE": return L10n.tr("Prüfung abgeschlossen")
        case "IN_PROGRESS": return L10n.tr("In Bearbeitung")
        case "WAITING_FOR_REVIEW": return L10n.tr("Wartet auf Prüfung")
        case "CANCELING": return L10n.tr("Wird zurückgezogen")
        default: return BlitzDisplayText.status(state)
        }
    }
}
