import SwiftUI

/// Public feature entry point for deep links and future media routes. The
/// viewer itself lives in the DesignSystem so feed rows, galleries, and detail
/// screens share the same controls and accessibility behaviour.
@MainActor
struct MediaRouteView: View {
    let post: PostCardModel
    let store: OctonautFeatureStore

    var body: some View {
        OctonautMediaViewer(
            post: post
        )
    }
}

/// Native presentation for a direct image or video URL received from a
/// universal link. Reddit media links do not include enough post metadata to
/// create a full `PostCardModel`, so this route stays intentionally focused on
/// the asset and offers the usual share and browser actions.
@MainActor
struct MediaURLView: View {
    let url: URL
    @Environment(\.openURL) private var openURL

    private var isVideo: Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host == "v.redd.it" || path.hasSuffix(".mp4") || path.hasSuffix(".mov") || path.hasSuffix(".webm")
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if isVideo {
                OctonautVideoDetailView(url: url)
            } else {
                OctonautZoomableImage(url: url, accessibilityLabel: "Shared Reddit image")
                    .padding(.horizontal)
            }
        }
        .navigationTitle(isVideo ? "Video" : "Image")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button { openURL(url) } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
            }
        }
    }
}

@MainActor
struct ExternalURLView: View {
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("External link", systemImage: "safari")
        } description: {
            Text(url.host ?? url.absoluteString)
        } actions: {
            Button("Open in Browser") { openURL(url) }
                .buttonStyle(.borderedProminent)
            ShareLink(item: url) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
        }
        .navigationTitle("Link")
        .navigationBarTitleDisplayMode(.inline)
    }
}
