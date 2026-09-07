import SwiftUI

struct GalleryMediaItem: Identifiable {
    let post: PostCardModel
    let page: Int
    let url: URL

    var id: String { "\(post.id):\(page)" }
    var isVideo: Bool { post.isVideo || ["video", "gif", "embeddedVideo"].contains(post.mediaKind) }
    var previewURL: URL? { isVideo ? post.thumbnailURL : url }

    static func items(from posts: [PostCardModel]) -> [Self] {
        posts.filter(\.hasMedia).flatMap { post in
            let urls = post.galleryURLs.isEmpty ? [post.mediaURL].compactMap { $0 } : post.galleryURLs
            return urls.enumerated().map { Self(post: post, page: $0.offset, url: $0.element) }
        }
    }
}

@MainActor
struct GalleryMediaTile: View {
    let item: GalleryMediaItem
    var blurNSFW = true
    let onOpen: () -> Void
    @State private var image: UIImage?
    @State private var failed = false

    private var isBlurred: Bool {
        item.post.isSpoiler || (item.post.isNSFW && blurNSFW)
    }

    private var aspectRatio: CGFloat {
        guard let image, image.size.height > 0 else { return 1 }
        return image.size.width / image.size.height
    }

    var body: some View {
        Button(action: onOpen) {
            Color(uiColor: .secondarySystemBackground)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .blur(radius: isBlurred ? 24 : 0)
                    } else if failed || item.previewURL == nil {
                        Image(systemName: item.isVideo ? "play.rectangle" : "photo.slash")
                            .font(.title2).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if item.isVideo || isBlurred {
                        Image(systemName: isBlurred ? "eye.slash.fill" : "play.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.post.isSensitive ? "Sensitive media. " : "")\(item.post.title), image \(item.page + 1) of \(max(1, item.post.galleryURLs.count))")
        .accessibilityHint("Opens the full screen media viewer")
        .task(id: item.previewURL) {
            image = nil
            failed = false
            guard let url = item.previewURL else { return }
            do {
                let result = try await OctonautImageCache.image(for: url)
                guard !Task.isCancelled else { return }
                image = result
            } catch is CancellationError {
                return
            } catch {
                failed = true
            }
        }
    }
}
