import SafariServices
import SwiftUI

struct OctonautBrowserDestination: Identifiable, Hashable {
    let url: URL

    var id: String { url.absoluteString }
}

struct OctonautBrowserView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

enum OctonautLoadState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case failed(String)
}

struct OctonautStateView<Content: View>: View {
    let state: OctonautLoadState
    let retry: (() -> Void)?
    @ViewBuilder let content: () -> Content

    init(
        state: OctonautLoadState, retry: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.state = state
        self.retry = retry
        self.content = content
    }

    var body: some View {
        switch state {
        case .idle, .loaded:
            content()
        case .loading:
            VStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { _ in OctonautSkeletonPostRow() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading")
        case .empty:
            ContentUnavailableView(
                "Nothing here yet", systemImage: "tray",
                description: Text("Try refreshing or changing your filters."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Could not load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if let retry {
                    Button("Retry", action: retry)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct OctonautSkeletonPostRow: View {
    @Environment(\.octonautTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(theme.tertiaryText.opacity(0.18)).frame(width: 22, height: 22)
                RoundedRectangle(cornerRadius: 3).fill(theme.tertiaryText.opacity(0.18)).frame(
                    width: 130, height: 11)
                Spacer()
                RoundedRectangle(cornerRadius: 3).fill(theme.tertiaryText.opacity(0.12)).frame(
                    width: 35, height: 11)
            }
            RoundedRectangle(cornerRadius: 4).fill(theme.tertiaryText.opacity(0.18)).frame(height: 16)
            RoundedRectangle(cornerRadius: 4).fill(theme.tertiaryText.opacity(0.12)).frame(
                width: 220, height: 12)
            HStack {
                RoundedRectangle(cornerRadius: 3).fill(theme.tertiaryText.opacity(0.12)).frame(
                    width: 68, height: 10)
                RoundedRectangle(cornerRadius: 3).fill(theme.tertiaryText.opacity(0.12)).frame(
                    width: 68, height: 10)
                Spacer()
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal)
        .redacted(reason: .placeholder)
    }
}

struct OctonautMediaPlaceholder: View {
    @Environment(\.octonautTheme) private var theme
    let title: String
    let symbol: String
    var isBlurred = false
    var action: (() -> Void)?

    var body: some View {
        Button(action: action ?? {}) {
            ZStack {
                Rectangle().fill(theme.elevatedSurface)
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(theme.tertiaryText)
                if !title.isEmpty {
                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: symbol == "play.fill" ? "play.fill" : "photo")
                            Text(title).lineLimit(1)
                            Spacer()
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.58))
                    }
                }
                if isBlurred {
                    Color.black.opacity(0.38)
                    VStack(spacing: 7) {
                        Image(systemName: "eye.slash")
                        Text("Sensitive media")
                            .font(.caption.weight(.semibold))
                        Text("Tap to reveal")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isBlurred ? "Sensitive media. Tap to reveal." : title)
    }
}

struct OctonautVoteControls: View {
    @Environment(\.octonautTheme) private var theme
    let score: Int
    let vote: Int
    var onVote: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Button {
                onVote?(vote == 1 ? 0 : 1)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16))
                    .frame(width: 22, height: 30)
            }
            .foregroundStyle(vote == 1 ? theme.upvote : theme.secondaryText)
            .accessibilityLabel(vote == 1 ? "Remove upvote" : "Upvote")
            Text(score.formatted())
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(
                    vote == 1 ? theme.upvote : vote == -1 ? theme.downvote : theme.secondaryText
                )
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Rectangle()
                .fill(theme.divider)
                .frame(width: 0.5, height: 18)
            Button {
                onVote?(vote == -1 ? 0 : -1)
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 16))
                    .frame(width: 22, height: 30)
            }
            .foregroundStyle(vote == -1 ? theme.downvote : theme.secondaryText)
            .accessibilityLabel(vote == -1 ? "Remove downvote" : "Downvote")
        }
        .padding(.horizontal, 4)
        .octonautActionPill(theme: theme)
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
    }
}

struct OctonautPostRow: View {
    @Environment(\.octonautTheme) private var theme
    @Environment(\.openURL) private var openURL
    let post: PostCardModel
    var bodyLineLimit: Int? = 4
    var showsFlair = true
    var mediaPreloader: OctonautFeedMediaPreloader?
    var onVote: ((Int) -> Void)?
    var onSave: (() -> Void)?
    var onSeen: (() -> Void)?
    var onMedia: ((Int) -> Void)?
    var onOpen: (() -> Void)?
    var onComments: (() -> Void)?
    var onCommunityOpen: (() -> Void)?
    var onCrosspost: (() -> Void)?
    var communityOpenAccessibilityHint = "Opens the post"

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(theme.tertiaryText)
                communityLabel
                if !post.author.isEmpty {
                    Text("• u/\(post.author)").font(.caption).foregroundStyle(theme.tertiaryText)
                    if let authorFlair = post.authorFlair {
                        OctonautUserFlairPill(flair: authorFlair)
                    }
                }
                Spacer()
                if post.isSticky { OctonautPill(title: "Pinned", color: theme.moderator) }
                if post.isNSFW { OctonautPill(title: "18+", color: theme.destructive) }
            }
            postTitle
            if showsFlair, let flair = post.flair {
                OctonautFlairPill(flair: flair)
            }
            if !post.body.isEmpty {
                postBody
            }
            if post.hasMedia {
                OctonautInlineMediaView(
                    post: post,
                    onOpen: onMedia,
                    preloader: mediaPreloader
                )
            }
            HStack(spacing: 0) {
                OctonautVoteControls(score: post.score, vote: post.vote, onVote: onVote)
                Spacer(minLength: 8)
                commentsControl
                Spacer(minLength: 8)
                OctonautIconLabel(
                    systemImage: post.isSeen ? "eye.slash" : "eye", title: post.age,
                    color: post.isSeen ? theme.seen : theme.secondaryText
                )
                .padding(.horizontal, 6)
                .octonautActionPill(theme: theme)
                Spacer(minLength: 8)
                Button {
                    onSave?()
                } label: {
                    Image(systemName: post.isSaved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 16))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .octonautActionPill(theme: theme)
                .foregroundStyle(post.isSaved ? theme.saved : theme.secondaryText)
                .accessibilityLabel(post.isSaved ? "Unsave post" : "Save post")
            }
            .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 13)
        .opacity(post.isSeen ? 0.62 : 1)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.divider).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "r/\(post.community), \(post.title), \(post.score) points, \(post.comments) comments"
        )
        .contextMenu {
            Button {
                onVote?(1)
            } label: {
                Label("Upvote", systemImage: "arrow.up")
            }
            Button {
                onVote?(-1)
            } label: {
                Label("Downvote", systemImage: "arrow.down")
            }
            Button {
                onSave?()
            } label: {
                Label(post.isSaved ? "Unsave" : "Save", systemImage: "bookmark")
            }
            Button {
                onSeen?()
            } label: {
                Label(post.isSeen ? "Mark Unseen" : "Mark Seen", systemImage: "eye")
            }
            if let onCrosspost {
                Button(action: onCrosspost) {
                    Label("Crosspost", systemImage: "arrow.triangle.branch")
                }
            }
            if let mediaURL = post.mediaURL {
                Button {
                    openURL(mediaURL)
                } label: {
                    Label("Open External Link", systemImage: "arrow.up.right.square")
                }
            }
            ShareLink(item: post.shareURL) { Label("Share Link", systemImage: "square.and.arrow.up") }
        }
    }

    @ViewBuilder
    private var commentsControl: some View {
        if let onComments {
            Button(action: onComments) {
                OctonautIconLabel(
                    systemImage: "bubble.left",
                    title: post.comments.formatted(),
                    color: theme.secondaryText
                )
                .padding(.horizontal, 6)
                .octonautActionPill(theme: theme)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(post.comments) comments")
            .accessibilityHint("Opens the comments")
        } else {
            OctonautIconLabel(
                systemImage: "bubble.left",
                title: post.comments.formatted(),
                color: theme.secondaryText
            )
            .padding(.horizontal, 6)
            .octonautActionPill(theme: theme)
        }
    }

    @ViewBuilder
    private var communityLabel: some View {
        if let onCommunityOpen {
            Button(action: onCommunityOpen) {
                communityText
            }
            .buttonStyle(.plain)
            .accessibilityHint(communityOpenAccessibilityHint)
        } else {
            communityText
        }
    }

    private var communityText: some View {
        Text("r/\(post.community)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.secondaryText)
    }

    @ViewBuilder
    private var postTitle: some View {
        if let onOpen {
            Button(action: onOpen) {
                titleText
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the post")
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(post.title)
            .font(.headline)
            .foregroundStyle(theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private var postBody: some View {
        if let onOpen {
            Button(action: onOpen) {
                bodyText
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the post")
        } else {
            bodyText
        }
    }

    private var bodyText: some View {
        Text(OctonautMarkdown.attributedString(from: post.body))
            .font(.subheadline)
            .foregroundStyle(theme.primaryText)
            .tint(theme.accent)
            .lineLimit(bodyLineLimit)
            .multilineTextAlignment(.leading)
    }
}

private extension View {
    func octonautActionPill(theme: OctonautTheme) -> some View {
        frame(height: 34)
            .background(theme.elevatedSurface, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(theme.divider.opacity(0.7), lineWidth: 0.75)
            }
    }
}

enum OctonautMarkdown {
    static func attributedString(from source: String) -> AttributedString {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var renderedLines: [AttributedString] = []
        var index = 0

        while index < lines.count {
            if let fence = openingFence(in: lines[index]) {
                index += 1
                while index < lines.count, !isClosingFence(lines[index], matching: fence) {
                    renderedLines.append(renderCode(lines[index]))
                    index += 1
                }
                if index < lines.count { index += 1 }
                continue
            }
            if index + 1 < lines.count,
               shouldJoinLinkLine(lines[index], to: lines[index + 1]) {
                renderedLines.append(renderInline(lines[index] + " " + lines[index + 1]))
                index += 2
                continue
            }
            if index + 1 < lines.count,
               let level = setextHeadingLevel(for: lines[index + 1]),
               !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                renderedLines.append(
                    renderInline(insertingMissingLinkSpacing(in: lines[index]), headingLevel: level)
                )
                index += 2
                continue
            }
            if let heading = atxHeading(in: lines[index]) {
                renderedLines.append(
                    renderInline(
                        insertingMissingLinkSpacing(in: heading.text),
                        headingLevel: heading.level
                    )
                )
            } else {
                renderedLines.append(renderInline(insertingMissingLinkSpacing(in: lines[index])))
            }
            index += 1
        }

        var result = AttributedString()
        for (lineIndex, line) in renderedLines.enumerated() {
            if lineIndex > 0 { result.append(AttributedString("\n")) }
            result.append(line)
        }
        return result
    }

    private struct Fence {
        let marker: Character
        let length: Int
    }

    private static func openingFence(in line: String) -> Fence? {
        let content = line.drop(while: { $0 == " " })
        guard line.count - content.count <= 3,
              let marker = content.first,
              marker == "`" || marker == "~" else { return nil }
        let length = content.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }

        let info = content.dropFirst(length)
        guard marker != "`" || !info.contains("`") else { return nil }
        return Fence(marker: marker, length: length)
    }

    private static func isClosingFence(_ line: String, matching fence: Fence) -> Bool {
        let content = line.drop(while: { $0 == " " })
        guard line.count - content.count <= 3 else { return false }
        let length = content.prefix(while: { $0 == fence.marker }).count
        guard length >= fence.length else { return false }
        return content.dropFirst(length).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func renderCode(_ source: String) -> AttributedString {
        var result = AttributedString(source)
        result.font = .system(.subheadline, design: .monospaced)
        return result
    }

    private static func shouldJoinLinkLine(_ line: String, to followingLine: String) -> Bool {
        guard let nextCharacter = followingLine.first,
              nextCharacter.isLetter || nextCharacter.isNumber,
              let expression = try? NSRegularExpression(
                pattern: #"(?:\[[^\]\r\n]+\]\([^)]+\)|https?://[^\s<>]+)$"#
              ) else { return false }
        return expression.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ) != nil
    }

    private static func renderInline(_ source: String, headingLevel: Int? = nil) -> AttributedString {
        var result = (try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(source)
        if let headingLevel {
            result.font = switch headingLevel {
            case 1: .title3.weight(.bold)
            case 2: .headline
            default: .subheadline.weight(.bold)
            }
        }
        return result
    }

    private static func atxHeading(in line: String) -> (level: Int, text: String)? {
        let content = line.drop(while: { $0 == " " })
        guard line.count - content.count <= 3 else { return nil }
        let level = content.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let remainder = content.dropFirst(level)
        guard remainder.first == " " || remainder.first == "\t" else { return nil }
        var text = String(remainder.drop(while: { $0 == " " || $0 == "\t" }))
        text = text.replacingOccurrences(
            of: #"[ \t]+#+[ \t]*$"#,
            with: "",
            options: .regularExpression
        )
        return (level, text)
    }

    private static func setextHeadingLevel(for line: String) -> Int? {
        let marker = line.trimmingCharacters(in: .whitespaces)
        guard !marker.isEmpty else { return nil }
        if marker.allSatisfy({ $0 == "=" }) { return 1 }
        if marker.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func insertingMissingLinkSpacing(in source: String) -> String {
        let replacements = [
            (#"(\[[^\]\r\n]+\]\([^)]+\))[\r\n]*(?=[\p{L}\p{N}])"#, "$1 "),
            (#"(https?://[^\s<>]+)[\r\n]+(?=[\p{L}\p{N}])"#, "$1 "),
        ]

        return replacements.reduce(source) { result, replacement in
            guard let expression = try? NSRegularExpression(pattern: replacement.0) else {
                return result
            }
            return expression.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement.1
            )
        }
    }
}

struct OctonautCompactPostRow: View {
    @Environment(\.octonautTheme) private var theme
    let post: PostCardModel
    var thumbnailOnRight = false
    var showsFlair = true
    var onVote: ((Int) -> Void)?
    var onSave: (() -> Void)?
    var onOpen: (() -> Void)?
    var onCommunityOpen: (() -> Void)?
    var communityOpenAccessibilityHint = "Opens the post"

    var body: some View {
        HStack(spacing: 11) {
            if !thumbnailOnRight { thumbnail }
            VStack(alignment: .leading, spacing: 5) {
                postTitle
                if showsFlair, let flair = post.flair {
                    OctonautFlairPill(flair: flair)
                }
                HStack(spacing: 3) {
                    communityLabel
                    Text("• \(post.author.isEmpty ? "deleted" : "u/\(post.author)")")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                    if let authorFlair = post.authorFlair, !post.author.isEmpty {
                        OctonautUserFlairPill(flair: authorFlair)
                    }
                }
                .lineLimit(1)
                HStack(spacing: 10) {
                    Text("↑ \(post.score.formatted())")
                    Text("💬 \(post.comments.formatted())")
                    Text(post.age)
                    Spacer()
                    Image(systemName: post.isSaved ? "bookmark.fill" : "bookmark")
                }
                .font(.caption2)
                .foregroundStyle(post.isSaved ? theme.saved : theme.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if thumbnailOnRight { thumbnail }
        }
        .padding(.horizontal)
        .padding(.vertical, 9)
        .opacity(post.isSeen ? 0.62 : 1)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.divider).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "r/\(post.community), \(post.title), \(post.score) points, \(post.comments) comments"
        )
        .contextMenu {
            Button {
                onVote?(1)
            } label: {
                Label("Upvote", systemImage: "arrow.up")
            }
            Button {
                onVote?(-1)
            } label: {
                Label("Downvote", systemImage: "arrow.down")
            }
            Button {
                onSave?()
            } label: {
                Label(post.isSaved ? "Unsave" : "Save", systemImage: "bookmark")
            }
        }
    }

    @ViewBuilder
    private var communityLabel: some View {
        if let onCommunityOpen {
            Button(action: onCommunityOpen) {
                communityText
            }
            .buttonStyle(.plain)
            .accessibilityHint(communityOpenAccessibilityHint)
        } else {
            communityText
        }
    }

    private var communityText: some View {
        Text("r/\(post.community)")
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
    }

    @ViewBuilder
    private var postTitle: some View {
        if let onOpen {
            Button(action: onOpen) {
                titleText
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the post")
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(post.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(theme.elevatedSurface)
            if let previewURL {
                OctonautAsyncImage(url: previewURL)
            } else {
                Image(systemName: post.isVideo ? "play.fill" : post.hasMedia ? "photo" : "doc.text")
                    .foregroundStyle(theme.tertiaryText)
            }
            if post.isVideo && !post.isSensitive {
                Image(systemName: "play.fill")
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.black.opacity(0.55), in: Circle())
            }
            if post.isSensitive {
                Image(systemName: "eye.slash").foregroundStyle(.white).padding(5).background(
                    .black.opacity(0.6), in: Circle())
            }
        }
        .frame(width: 70, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }

    private var previewURL: URL? {
        if let thumbnailURL = post.thumbnailURL { return thumbnailURL }
        if let galleryURL = post.galleryURLs.first { return galleryURL }
        if post.mediaKind == "image" || post.mediaKind == "gif" { return post.mediaURL }
        return nil
    }
}

struct OctonautCommunityRow: View {
    @Environment(\.octonautTheme) private var theme
    let community: CommunityCardModel
    var onFavorite: (() -> Void)?
    var onSubscribe: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            OctonautCommunityIcon(url: community.iconURL, tint: theme.accent)
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("r/\(community.name)")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(community.memberCount.map { "\($0.formatted()) members" } ?? "Community")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            HStack(spacing: 8) {
                Button {
                    onFavorite?()
                } label: {
                    Image(systemName: community.isFavorite ? "star.fill" : "star")
                        .frame(width: 24, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(community.isFavorite ? theme.saved : theme.secondaryText)
                .accessibilityLabel(community.isFavorite ? "Remove favorite" : "Add favorite")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(theme.divider).frame(height: 0.5) }
        .contextMenu {
            Button {
                onSubscribe?()
            } label: {
                Label(
                    community.isSubscribed ? "Unsubscribe" : "Subscribe", systemImage: "person.badge.plus")
            }
            Button {
                onFavorite?()
            } label: {
                Label(community.isFavorite ? "Remove Favorite" : "Add Favorite", systemImage: "star")
            }
        }
    }
}

private struct OctonautCommunityIcon: View {
    let url: URL?
    let tint: Color
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.15))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(tint)
            }
        }
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = try? await OctonautImageCache.image(for: url)
        }
    }
}

struct OctonautCommentRow: View {
    @Environment(\.octonautTheme) private var theme
    let comment: CommentCardModel
    var onCollapse: (() -> Void)?
    var onVote: ((Int) -> Void)?
    var onReply: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Rectangle()
                .fill(theme.commentDepth[comment.depth % max(theme.commentDepth.count, 1)])
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 7) {
                Button(action: { onCollapse?() }) {
                    HStack(spacing: 6) {
                        Image(systemName: comment.isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.bold))
                        Text(comment.author.isEmpty ? "[deleted]" : "u/\(comment.author)")
                            .font(.caption.weight(.semibold))
                        if let authorFlair = comment.authorFlair, !comment.author.isEmpty {
                            OctonautUserFlairPill(flair: authorFlair)
                        }
                        if comment.isModerator { OctonautPill(title: "MOD", color: theme.moderator) }
                        Text("• \(comment.age)").font(.caption).foregroundStyle(theme.tertiaryText)
                        Spacer()
                    }
                    .foregroundStyle(theme.primaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(comment.isCollapsed ? "Expand comment" : "Collapse comment")
                if !comment.isCollapsed {
                    if !comment.body.isEmpty {
                        Text(OctonautMarkdown.attributedString(from: comment.body))
                            .font(.subheadline)
                            .foregroundStyle(theme.primaryText)
                            .tint(theme.accent)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 13) {
                        OctonautVoteControls(score: comment.score, vote: comment.vote, onVote: onVote)
                        Button {
                            onReply?()
                        } label: {
                            Label("Reply", systemImage: "arrowshape.turn.up.left")
                        }
                        .foregroundStyle(theme.reply)
                        Button(action: { onCollapse?() }) { Label("Collapse", systemImage: "chevron.up") }
                            .foregroundStyle(theme.secondaryText)
                    }
                    .font(.caption)
                } else {
                    Text("Show comment")
                        .font(.caption)
                        .foregroundStyle(theme.accent)
                }
            }
        }
        .padding(.leading, min(CGFloat(comment.depth) * 8, 48))
        .padding(.trailing)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.divider).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityValue("Depth \(comment.depth), \(comment.isCollapsed ? "collapsed" : "expanded")")
        .contextMenu {
            Button {
                onVote?(1)
            } label: {
                Label("Upvote", systemImage: "arrow.up")
            }
            Button {
                onVote?(-1)
            } label: {
                Label("Downvote", systemImage: "arrow.down")
            }
            Button {
                onReply?()
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            Button {
                onCollapse?()
            } label: {
                Label(comment.isCollapsed ? "Expand" : "Collapse", systemImage: "chevron.down")
            }
        }
    }
}
