import SwiftUI
import UIKit

enum SummaryCardState: Sendable {
    case idle
    case loading
    case summary(ContentSummary)
    case excerpts([String])
    case unavailable(String)
    case failed(String)
}

@MainActor
struct SummaryCardView: View {
    let title: String
    let input: SummaryInput
    let intelligence: any IntelligenceService
    let cache: InMemorySummaryCache
    let modelFamily: String
    let automatic: Bool
    let useFallback: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state: SummaryCardState = .idle
    @State private var isExpanded = true
    @State private var hasRequested = false
    @State private var preparedKey: SummaryCacheKey?

    enum SummaryInput: Sendable {
        case post(PostSummaryInput)
        case comments(CommentSummaryInput)

        var id: String {
            switch self {
            case .post(let input):
                return "post:\(input.id):\(DeterministicExcerptEngine.contentHash(title: input.title, body: input.body))"
            case .comments(let input):
                let body = input.comments.map(\.text).joined(separator: "\n\n")
                return "comments:\(input.postID):\(DeterministicExcerptEngine.contentHash(title: "", body: body))"
            }
        }

        var fallback: [String] {
            switch self {
            case .post(let input):
                return DeterministicExcerptEngine.excerpts(title: input.title, body: input.body)
            case .comments(let input):
                let body = input.comments.map(\.text).joined(separator: "\n\n")
                return DeterministicExcerptEngine.excerpts(title: "", body: body)
            }
        }

        func cacheKey(modelFamily: String) -> SummaryCacheKey {
            switch self {
            case .post(let input):
                return SummaryCacheKey(contentID: "post:\(input.id)", title: input.title,
                                       body: input.body, modelFamily: modelFamily)
            case .comments(let input):
                let body = input.comments.map { "\($0.id):\($0.text)" }.joined(separator: "\n\n")
                return SummaryCacheKey(contentID: "comments:\(input.postID)", title: "",
                                       body: body, modelFamily: modelFamily)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy) { isExpanded.toggle() }
                if isExpanded, !hasRequested, automatic { Task { await requestSummary() } }
            } label: {
                HStack(spacing: 8) {
                    Label(title, systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Generated from selected visible text using the configured summary provider")

            if isExpanded {
                content
            }
        }
        .padding(13)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 10)
        .task(id: input.cacheKey(modelFamily: modelFamily)) {
            let key = input.cacheKey(modelFamily: modelFamily)
            if preparedKey != key {
                preparedKey = key
                state = .idle
            } else {
                switch state {
                case .summary, .excerpts, .unavailable, .failed:
                    return
                case .idle, .loading:
                    break
                }
            }
            hasRequested = false
            let cached = await cache.value(for: key)
            guard !Task.isCancelled else { return }
            if let cached {
                state = .summary(cached)
                hasRequested = true
                return
            }
            guard automatic, !hasRequested else { return }
            await requestSummary()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            Button("Summarize") { Task { await requestSummary() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Preparing summary…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .summary(let summary):
            summaryText(summary.bullets)
            HStack {
                Text(summary.origin.label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Copy") { UIPasteboard.general.string = summary.bullets.map { "• \($0)" }.joined(separator: "\n") }
                    .font(.caption)
                Button("Regenerate") { Task { await requestSummary(force: true) } }
                    .font(.caption)
            }
        case .excerpts(let excerpts):
            Text("Key excerpts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            summaryText(excerpts)
            Text("Source excerpts shown because the on-device model is unavailable")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .unavailable(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if useFallback {
                Button("Show Key excerpts") { showFallback() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button("Try Again") { Task { await requestSummary(force: true) } }
                .buttonStyle(.bordered)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if useFallback {
                Button("Show Key excerpts") { showFallback() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button("Try Again") { Task { await requestSummary(force: true) } }
                .buttonStyle(.bordered)
        }
    }

    private func summaryText(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "circle.fill")
                    .labelStyle(SummaryBulletLabelStyle())
                    .font(.subheadline)
            }
        }
    }

    private func requestSummary(force: Bool = false) async {
        if hasRequested && !force { return }
        hasRequested = true
        let key = input.cacheKey(modelFamily: modelFamily)
        if !force {
            let cached = await cache.value(for: key)
            guard !Task.isCancelled, preparedKey == key else { return }
            if let cached {
                state = .summary(cached)
                return
            }
        }
        guard preparedKey == key else { return }
        state = .loading
        do {
            let result: ContentSummary
            switch input {
            case .post(let value): result = try await intelligence.summarizePost(value)
            case .comments(let value): result = try await intelligence.summarizeComments(value)
            }
            guard !Task.isCancelled, preparedKey == key else { return }
            await cache.insert(result, for: key)
            guard !Task.isCancelled, preparedKey == key else { return }
            state = .summary(result)
        } catch let error as IntelligenceError {
            guard !Task.isCancelled, preparedKey == key else { return }
            if case .unavailable(let availability) = error {
                state = .unavailable(availability.userMessage)
            } else {
                state = .failed(error.localizedDescription)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, preparedKey == key else { return }
            state = .failed(error.localizedDescription)
        }
    }

    private func showFallback() {
        let values = input.fallback
        state = values.isEmpty ? .failed("There are no readable excerpts in this content.") : .excerpts(values)
    }
}

private struct SummaryBulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .font(.system(size: 5))
                .foregroundStyle(.secondary)
            configuration.title
        }
    }
}
