import SwiftUI

/// A split view that keeps a **stable view hierarchy** regardless of orientation.
/// Switching between bottom/right only changes frame sizes — child views are never
/// destroyed or recreated, which preserves terminal NSView rendering state.
struct TerminalSplitView<Content: View, Panel: View>: View {
    let isHorizontal: Bool
    let showPanel: Bool
    @Binding var panelSize: CGFloat
    let minPanelSize: CGFloat
    let minContentSize: CGFloat
    var onResizeEnded: () -> Void = {}
    @ViewBuilder let content: () -> Content
    @ViewBuilder let panel: () -> Panel

    @State private var dragStartPanelSize: CGFloat?
    @State private var isHoveringDivider = false
    @State private var isDraggingDivider = false

    private let dividerThickness: CGFloat = 1
    private let grabAreaThickness: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let total = axisLength(in: geo.size)
            let visibleDividerThickness = showPanel ? dividerThickness : 0
            let clampedPanelSize = showPanel ? clampedPanelSize(panelSize, total: total) : 0
            let contentSize = max(total - clampedPanelSize - visibleDividerThickness, 0)
            let dividerOffset = contentSize
            let panelOffset = contentSize + visibleDividerThickness

            // Always the same ZStack → stable view identity for both children
            ZStack(alignment: .topLeading) {
                // Content — pinned to top-left
                content()
                    .frame(
                        width: isHorizontal ? contentSize : geo.size.width,
                        height: isHorizontal ? geo.size.height : contentSize,
                        alignment: .topLeading
                    )

                // Panel — stays in the hierarchy even when hidden so orientation flips do not
                // recreate the underlying NSView subtree.
                panel()
                    .frame(
                        width: isHorizontal ? clampedPanelSize : geo.size.width,
                        height: isHorizontal ? geo.size.height : clampedPanelSize,
                        alignment: .topLeading
                    )
                    .offset(
                        x: isHorizontal ? panelOffset : 0,
                        y: isHorizontal ? 0 : panelOffset
                    )
                    .opacity(showPanel ? 1 : 0)
                    .allowsHitTesting(showPanel)

                // Visible divider line
                Rectangle()
                    .fill(dividerColor)
                    .frame(
                        width: isHorizontal ? visibleDividerThickness : geo.size.width,
                        height: isHorizontal ? geo.size.height : visibleDividerThickness
                    )
                    .offset(
                        x: isHorizontal ? dividerOffset : 0,
                        y: isHorizontal ? 0 : dividerOffset
                    )
                    .opacity(showPanel ? 1 : 0)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.15), value: isHoveringDivider)
                    .animation(.easeInOut(duration: 0.15), value: isDraggingDivider)

                dividerHandle(in: geo.size, dividerOffset: dividerOffset, total: total)
                    .opacity(showPanel ? 1 : 0)
                    .allowsHitTesting(showPanel)
                    .zIndex(1)
            }
            .onDisappear {
                dragStartPanelSize = nil
                isDraggingDivider = false
                isHoveringDivider = false
            }
        }
    }

    private var dividerColor: Color {
        if isHoveringDivider || isDraggingDivider {
            return Color.accentColor.opacity(0.6)
        }
        return Color(nsColor: .separatorColor)
    }

    private func dividerHandle(in size: CGSize, dividerOffset: CGFloat, total: CGFloat) -> some View {
        // Use a nearly transparent fill instead of Color.clear so AppKit always has a reliable
        // hit-testable surface above the embedded terminal NSView.
        Rectangle()
            .fill(Color.black.opacity(0.001))
            .contentShape(Rectangle())
            .frame(
                width: isHorizontal ? grabAreaThickness : size.width,
                height: isHorizontal ? size.height : grabAreaThickness
            )
            .offset(
                x: isHorizontal ? dividerOffset - ((grabAreaThickness - dividerThickness) / 2) : 0,
                y: isHorizontal ? 0 : dividerOffset - ((grabAreaThickness - dividerThickness) / 2)
            )
            .resizeCursor(isHorizontal ? .resizeLeftRight : .resizeUpDown, isHovering: $isHoveringDivider)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let startSize = dragStartPanelSize ?? clampedPanelSize(panelSize, total: total)
                        dragStartPanelSize = startSize
                        isDraggingDivider = true
                        panelSize = clampedPanelSize(startSize + dragDelta(for: value), total: total)
                    }
                    .onEnded { value in
                        let startSize = dragStartPanelSize ?? clampedPanelSize(panelSize, total: total)
                        panelSize = clampedPanelSize(startSize + dragDelta(for: value), total: total)
                        dragStartPanelSize = nil
                        isDraggingDivider = false
                        onResizeEnded()
                    }
            )
    }

    private func axisLength(in size: CGSize) -> CGFloat {
        isHorizontal ? size.width : size.height
    }

    private func dragDelta(for value: DragGesture.Value) -> CGFloat {
        isHorizontal ? -value.translation.width : -value.translation.height
    }

    private func clampedPanelSize(_ proposed: CGFloat, total: CGFloat) -> CGFloat {
        let maxPanelSize = max(total - minContentSize - dividerThickness, 0)
        let minAllowedPanelSize = min(minPanelSize, maxPanelSize)
        return min(max(proposed, minAllowedPanelSize), maxPanelSize)
    }
}

// MARK: - Cursor

private extension View {
    func resizeCursor(_ cursor: NSCursor, isHovering: Binding<Bool>) -> some View {
        modifier(ResizeCursorModifier(cursor: cursor, isHovering: isHovering))
    }
}

private struct ResizeCursorModifier: ViewModifier {
    let cursor: NSCursor
    @Binding var isHovering: Bool

    @State private var hasPushedCursor = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    if !hasPushedCursor {
                        cursor.push()
                        hasPushedCursor = true
                    }
                case .ended:
                    isHovering = false
                    if hasPushedCursor {
                        NSCursor.pop()
                        hasPushedCursor = false
                    }
                }
            }
            .onDisappear {
                isHovering = false
                if hasPushedCursor {
                    NSCursor.pop()
                    hasPushedCursor = false
                }
            }
    }
}
