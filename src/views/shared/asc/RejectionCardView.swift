import SwiftUI

/// Shared rejection feedback card used by both ASCOverview and ReviewView.
struct RejectionCardView<Footer: View>: View {
    var asc: ASCManager
    var version: ASCAppStoreVersion
    @ViewBuilder var footer: () -> Footer
    @State private var expanded = true

    private var isCurrentlyRejected: Bool { ASCReleaseStatus.rejectedStates.contains(ASCReleaseStatus.normalize(version.attributes.effectiveState)) }
    private var cardColor: Color { isCurrentlyRejected ? .red : .secondary }

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
        .background(cardColor.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(cardColor.opacity(0.15), lineWidth: 1)
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
            Image(systemName: isCurrentlyRejected ? "xmark.circle.fill" : "clock.arrow.circlepath")
                .font(.system(size: 15))
                .foregroundStyle(cardColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(isCurrentlyRejected ? L10n.tr("Version \(version.attributes.versionString) abgelehnt") : L10n.tr("Prüfungsverlauf für Version \(version.attributes.versionString)"))
                    .font(BlitzLayout.sectionTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: - Review History

    @ViewBuilder
    private var reviewHistory: some View {
        let submissions = asc.reviewSubmissions.filter { submission in
            (asc.reviewSubmissionItemsBySubmissionId[submission.id] ?? []).contains { $0.appStoreVersionId == version.id }
        }
        if !submissions.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("Prüfungsverlauf"))
                    .font(BlitzLayout.sectionTitle)

                ForEach(submissions.prefix(5)) { submission in
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
            if !submissionItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("Prüfungsbestandteile"))
                        .font(BlitzLayout.sectionTitle)

                    ForEach(submissionItems) { item in
                        HStack(spacing: 8) {
                            Image(systemName: itemSymbol(item))
                                .foregroundStyle(itemColor(item))
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

    private func itemSymbol(_ item: ASCReviewSubmissionItem) -> String {
        switch item.attributes.state {
        case "REJECTED": item.attributes.resolved == true ? "checkmark.circle" : "xmark.circle.fill"
        case "ACCEPTED", "APPROVED": "checkmark.circle.fill"
        case "READY_FOR_REVIEW": "paperplane"
        default: "questionmark.circle"
        }
    }

    private func itemColor(_ item: ASCReviewSubmissionItem) -> Color {
        switch item.attributes.state {
        case "REJECTED": item.attributes.resolved == true ? .orange : .red
        case "ACCEPTED", "APPROVED": .green
        case "READY_FOR_REVIEW": .orange
        default: .secondary
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
