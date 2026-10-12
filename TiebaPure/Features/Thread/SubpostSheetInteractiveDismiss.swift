import SwiftUI

struct SubpostSheetDismissAction {
    let handler: () -> Void

    func callAsFunction() {
        handler()
    }
}

private struct SubpostSheetDismissActionKey: EnvironmentKey {
    static let defaultValue = SubpostSheetDismissAction(handler: {})
}

private extension EnvironmentValues {
    var subpostSheetDismissAction: SubpostSheetDismissAction {
        get { self[SubpostSheetDismissActionKey.self] }
        set { self[SubpostSheetDismissActionKey.self] = newValue }
    }
}

struct SubpostSheetDismissButton: View {
    @Environment(\.subpostSheetDismissAction) private var dismissAction

    var body: some View {
        Button("完成") {
            dismissAction()
        }
        .accessibilityHint("关闭楼中楼并返回帖子")
    }
}

/// Delegates normal sheet motion to SwiftUI and adds an edge-only dismiss gesture.
struct SubpostSheetInteractiveDismissSurface<Content: View>: View {
    var isEnabled = true
    let onDismiss: () -> Void
    private let content: Content

    init(
        isEnabled: Bool = true,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.isEnabled = isEnabled
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            content
                .background(Color(uiColor: .systemBackground).ignoresSafeArea())
                .contentShape(Rectangle())
                .accessibilityIdentifier("subpost-sheet-surface")
                .simultaneousGesture(
                    edgeDismissGesture(containerWidth: proxy.size.width),
                    isEnabled: isEnabled
                )
                .environment(
                    \.subpostSheetDismissAction,
                    SubpostSheetDismissAction(handler: onDismiss)
                )
                .accessibilityAction(named: "关闭楼中楼") {
                    onDismiss()
                }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.clear)
    }

    private func edgeDismissGesture(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: SubpostSheetEdgeDismissPolicy.minimumDistance)
            .onEnded { value in
                guard SubpostSheetEdgeDismissPolicy.shouldDismiss(
                    startLocation: value.startLocation,
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    containerWidth: containerWidth
                ) else { return }
                onDismiss()
            }
    }
}

enum SubpostSheetEdgeDismissPolicy {
    static let minimumDistance: CGFloat = 14
    static let leadingEdgeWidth: CGFloat = 44
    static let horizontalIntentRatio: CGFloat = 1.25
    static let minimumCommitDistance: CGFloat = 72
    static let commitWidthRatio: CGFloat = 0.22

    static func shouldDismiss(
        startLocation: CGPoint,
        translation: CGSize,
        predictedEndTranslation: CGSize,
        containerWidth: CGFloat
    ) -> Bool {
        guard containerWidth > 0,
              startLocation.x <= leadingEdgeWidth,
              translation.width > 0,
              translation.width > abs(translation.height) * horizontalIntentRatio
        else { return false }

        let threshold = max(minimumCommitDistance, containerWidth * commitWidthRatio)
        return translation.width >= threshold
            || predictedEndTranslation.width >= threshold
    }
}
