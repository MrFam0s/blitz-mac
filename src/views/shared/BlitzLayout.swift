import SwiftUI

/// Shared spacing and typography for the app's navigation and detail pages.
enum BlitzLayout {
    static let pageInset: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let fieldSpacing: CGFloat = 8
    static let cardInset: CGFloat = 12
    static let pageTitle: Font = .system(size: 15, weight: .semibold)
    static let sectionTitle: Font = .system(size: 13, weight: .semibold)
    static let bodyFont: Font = .system(size: 13)
    static let toolbarFont: Font = .system(size: 12)
}

extension View {
    func blitzToolbar() -> some View {
        self
            .font(BlitzLayout.toolbarFont)
            .controlSize(.small)
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
