import SwiftUI

struct ReviewsView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }

    var body: some View {
        ASCCredentialGate(
            appState: appState,
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(appState: appState, asc: asc, tab: .reviews, platform: appState.activeProject?.platform ?? .iOS, allowWithoutLocalProject: true) {
                reviewsContent
            }
        }
        .task(id: "\(appState.activeProjectId ?? ""):\(asc.credentialActivationRevision)") {
            await asc.ensureTabData(.reviews)
        }
    }

    @ViewBuilder
    private var reviewsContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Reviews")
                    .font(BlitzLayout.pageTitle)
                Spacer()
                ASCTabRefreshButton(asc: asc, tab: .reviews, helpText: "Refresh reviews")
            }
            .blitzToolbar()

            Divider()

            if asc.customerReviews.isEmpty {
                if asc.isTabLoading(.reviews) {
                    ASCTabLoadingPlaceholder(
                        title: "Loading Reviews",
                        message: "Fetching customer ratings and review text."
                    )
                } else {
                    ContentUnavailableView(
                        "No Reviews",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("No customer reviews found for this app.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List(asc.customerReviews) { review in
                    reviewRow(review)
                        .listRowInsets(EdgeInsets(top: 12, leading: BlitzLayout.pageInset, bottom: 12, trailing: BlitzLayout.pageInset))
                }
                .listStyle(.plain)
            }
        }
    }

    private func reviewRow(_ review: ASCCustomerReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BlitzFlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
                HStack(spacing: 8) {
                    starRating(review.attributes.rating)
                    if let territory = review.attributes.territory {
                        Text(flagEmoji(territory))
                            .font(.callout)
                    }
                }
                .fixedSize()
                if let date = review.attributes.createdDate {
                    Text(ascShortDate(date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let title = review.attributes.title, !title.isEmpty {
                Text(title)
                    .font(BlitzLayout.sectionTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let body = review.attributes.body, !body.isEmpty {
                Text(body)
                    .font(BlitzLayout.bodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 12) {
                if let nickname = review.attributes.reviewerNickname {
                    Text("by \(nickname)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let appId = asc.app?.id {
                    Link(destination: URL(string: "https://appstoreconnect.apple.com/apps/\(appId)/appstore/ios/customerreviews")!) {
                        Text("Reply")
                            .font(.caption.weight(.medium))
                    }
                    .fixedSize()
                }
            }
        }
    }

    private func starRating(_ rating: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(i <= rating ? .yellow : .secondary)
            }
        }
    }

    private func flagEmoji(_ territory: String) -> String {
        // Convert country code to flag emoji (regional indicator symbols)
        guard territory.count == 2 else { return "" }
        let base: UInt32 = 127397
        return territory.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(base + $0.value)
        }.map { String($0) }.joined()
    }
}
