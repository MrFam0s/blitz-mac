// Modified for the AmoSystems Blitz Neo maintenance fork (2026).
import SwiftUI

/// Shared hierarchy for setup, release and utility dialogs.
struct BlitzSetupHeader: View {
    let title: String
    let subtitle: String

    init(_ title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A persistent field label without the control's second visual label.
/// Controls retain their own accessibility labels for keyboard/VoiceOver use.
struct BlitzSetupField<Content: View>: View {
    let title: String
    let hint: String?
    let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BlitzLayout.fieldSpacing) {
            Text(title)
                .font(.callout.weight(.medium))
            content
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Fits short dialog content and scrolls longer content above the fixed footer.
struct BlitzSetupScrollArea<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: SetupContentHeight.self, value: geometry.size.height)
                    }
                }
        }
        .frame(height: min(maxHeight, max(1, contentHeight)))
        .onPreferenceChange(SetupContentHeight.self) { contentHeight = $0 }
    }
}

private struct SetupContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
