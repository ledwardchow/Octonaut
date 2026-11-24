import SwiftUI

struct MarkPostSeenWhileVisible: ViewModifier {
    let post: PostCardModel
    let enabled: Bool
    let store: OctonautFeatureStore
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .onScrollVisibilityChange(threshold: 0.6) { isVisible = $0 }
            .onDisappear { isVisible = false }
            .task(id: enabled && isVisible) {
                guard enabled, isVisible, !post.isSeen else { return }
                await store.markSeenAfterScrollDwell(postID: post.id) { isVisible }
            }
    }
}
