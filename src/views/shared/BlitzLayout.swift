import SwiftUI

/// Shared spacing and typography for the app's navigation and detail pages.
enum BlitzLayout {
    static let pageInset: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let pageTitle: Font = .system(size: 15, weight: .semibold)
}

extension View {
    func blitzToolbar() -> some View {
        self
            .font(.callout)
            .controlSize(.regular)
            .frame(minHeight: 24)
            .padding(.horizontal, BlitzLayout.pageInset)
            .padding(.vertical, 8)
            .background(.bar)
    }

    func blitzPagePadding() -> some View {
        self
            .padding(.horizontal, BlitzLayout.pageInset)
            .padding(.vertical, BlitzLayout.sectionSpacing)
    }
}
