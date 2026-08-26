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
    let automatic: Bool
    let useFallback: Bool

    @State private var state: SummaryCardState = .idle
    @State private var isExpanded = true
    @State private var hasRequested = false

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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
                if isExpanded, !hasRequested, automatic { Task { await requestSummary() } }
            } label: {
                HStack(spacing: 8) {
                    Label(title, systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if case .loading = state { ProgressView().controlSize(.small) }
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
        .task(id: input.id) {
            state = .idle
            hasRequested = false
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
            Button("Try again") { Task { await requestSummary(force: true) } }
                .font(.caption)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if useFallback {
                Button("Show Key excerpts") { showFallback() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button("Retry") { Task { await requestSummary(force: true) } }
                .font(.caption)
        }
    }

    private func summaryText(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "circle.fill")
                    .labelStyle(SummaryBulletLabelStyle())
                    .font(.body)
            }
        }
    }

    private func requestSummary(force: Bool = false) async {
        if hasRequested && !force { return }
        hasRequested = true
        state = .loading
        do {
            let result: ContentSummary
            switch input {
            case .post(let value): result = try await intelligence.summarizePost(value)
            case .comments(let value): result = try await intelligence.summarizeComments(value)
            }
            guard !Task.isCancelled else { return }
            state = .summary(result)
        } catch let error as IntelligenceError {
            guard !Task.isCancelled else { return }
            if case .unavailable(let availability) = error {
                state = .unavailable(availability.userMessage)
            } else {
                state = .failed(error.localizedDescription)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
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
