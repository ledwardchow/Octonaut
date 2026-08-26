import SwiftUI
import UIKit

/// Semantic colors used by feature views. Keeping colors here makes custom themes
/// possible without coupling a screen to a particular palette.
struct OctonautTheme: Sendable {
    var background: Color
    var surface: Color
    var elevatedSurface: Color
    var divider: Color
    var primaryText: Color
    var secondaryText: Color
    var tertiaryText: Color
    var accent: Color
    var accentText: Color
    var upvote: Color
    var downvote: Color
    var moderator: Color
    var reply: Color
    var saved: Color
    var seen: Color
    var destructive: Color
    var commentDepth: [Color]

    static let system = OctonautTheme(
        background: Color(uiColor: .systemBackground),
        surface: Color(uiColor: .secondarySystemBackground),
        elevatedSurface: Color(uiColor: .tertiarySystemBackground),
        divider: Color(uiColor: .separator),
        primaryText: Color(uiColor: .label),
        secondaryText: Color(uiColor: .secondaryLabel),
        tertiaryText: Color(uiColor: .tertiaryLabel),
        accent: .orange,
        accentText: .white,
        upvote: .orange,
        downvote: .blue,
        moderator: .green,
        reply: .purple,
        saved: .yellow,
        seen: .gray,
        destructive: .red,
        commentDepth: [.orange, .teal, .purple, .pink, .green, .indigo]
    )

    static let midnight = OctonautTheme(
        background: Color(red: 0.025, green: 0.035, blue: 0.065),
        surface: Color(red: 0.06, green: 0.075, blue: 0.12),
        elevatedSurface: Color(red: 0.10, green: 0.12, blue: 0.18),
        divider: Color.white.opacity(0.14),
        primaryText: .white,
        secondaryText: Color.white.opacity(0.72),
        tertiaryText: Color.white.opacity(0.48),
        accent: .orange,
        accentText: .white,
        upvote: .orange,
        downvote: .cyan,
        moderator: .mint,
        reply: .purple,
        saved: .yellow,
        seen: .gray,
        destructive: .red,
        commentDepth: [.orange, .teal, .purple, .pink, .green, .indigo]
    )
}

private struct OctonautThemeKey: EnvironmentKey {
    static let defaultValue = OctonautTheme.system
}

extension EnvironmentValues {
    var octonautTheme: OctonautTheme {
        get { self[OctonautThemeKey.self] }
        set { self[OctonautThemeKey.self] = newValue }
    }
}

extension View {
    func octonautTheme(_ theme: OctonautTheme) -> some View {
        environment(\.octonautTheme, theme)
    }
}

struct OctonautSectionHeader: View {
    @Environment(\.octonautTheme) private var theme
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
                .textCase(.uppercase)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct OctonautPill: View {
    @Environment(\.octonautTheme) private var theme
    let title: String
    var color: Color?

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color ?? theme.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((color ?? theme.secondaryText).opacity(0.14), in: Capsule())
    }
}

struct OctonautFlairPill: View {
    @Environment(\.octonautTheme) private var theme
    let flair: Flair

    private var backgroundColor: Color {
        flair.backgroundColor.flatMap(Color.init(octonautHex:)) ?? theme.accent
    }

    private var foregroundColor: Color {
        switch flair.textColor?.lowercased() {
        case "light": .white
        case "dark": .black
        case let value?: Color(octonautHex: value) ?? .white
        case nil: .white
        }
    }

    var body: some View {
        Text(flair.text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(backgroundColor, in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Post flair: \(flair.text)")
    }
}

struct OctonautUserFlairPill: View {
    @Environment(\.octonautTheme) private var theme
    let flair: Flair

    private var backgroundColor: Color {
        flair.backgroundColor.flatMap(Color.init(octonautHex:)) ?? theme.secondaryText.opacity(0.16)
    }

    private var foregroundColor: Color {
        switch flair.textColor?.lowercased() {
        case "light": .white
        case "dark": .black
        case let value?: Color(octonautHex: value) ?? theme.secondaryText
        case nil: theme.secondaryText
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(flair.emojiURLs.enumerated()), id: \.offset) { _, url in
                OctonautFlairEmoji(url: url)
            }
            if !flair.text.isEmpty {
                Text(flair.text)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(foregroundColor)
                    .lineLimit(1)
            }
        }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor, in: Capsule())
            .accessibilityLabel(flair.text.isEmpty ? "User flair with custom emoji" : "User flair: \(flair.text)")
    }
}

private struct OctonautFlairEmoji: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
        .task(id: url) {
            image = try? await OctonautImageCache.image(for: url)
        }
    }
}

private extension Color {
    init?(octonautHex value: String) {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6 || hex.count == 8,
              let number = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        self.init(
            .sRGB,
            red: Double((number >> (hasAlpha ? 24 : 16)) & 0xFF) / 255,
            green: Double((number >> (hasAlpha ? 16 : 8)) & 0xFF) / 255,
            blue: Double((number >> (hasAlpha ? 8 : 0)) & 0xFF) / 255,
            opacity: hasAlpha ? Double(number & 0xFF) / 255 : 1
        )
    }
}

struct OctonautIconLabel: View {
    let systemImage: String
    let title: String
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .frame(width: 18, height: 18)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
            .foregroundStyle(color)
            .fixedSize(horizontal: true, vertical: false)
    }
}
