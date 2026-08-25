import SwiftUI

@MainActor
struct GalleryPagerView: View {
    let posts: [PostCardModel]
    let store: LedditFeatureStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPost: PostCardModel?

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if posts.isEmpty {
                ContentUnavailableView("No media posts", systemImage: "photo.on.rectangle.angled")
                    .foregroundStyle(.white)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(posts) { post in
                            Button { selectedPost = post } label: {
                                ZStack(alignment: .bottomLeading) {
                                    LedditAsyncImage(url: post.thumbnailURL ?? post.mediaURL ?? post.galleryURLs.first)
                                        .frame(maxWidth: .infinity)
                                        .containerRelativeFrame(.vertical)
                                        .clipped()
                                    LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(post.title).font(.headline).lineLimit(3)
                                        Text("r/\(post.community) • \(post.score.formatted()) points")
                                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                                    }
                                    .foregroundStyle(.white)
                                    .padding()
                                }
                            }
                            .buttonStyle(.plain)
                            .containerRelativeFrame(.vertical)
                        }
                    }
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
            }
            HStack {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Close gallery")
                Spacer()
            }
            .padding()
            .foregroundStyle(.white)
            .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
        }
        .fullScreenCover(item: $selectedPost) { post in
            LedditMediaViewer(post: post)
        }
    }
}
