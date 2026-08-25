import Foundation
import CryptoKit

enum SummaryEligibility {
    static let postCharacterThreshold = 850
    static let commentCharacterThreshold = 1_000

    static func post(_ post: Post, manual: Bool = false) -> Bool {
        guard !post.isArchived || manual else { return false }
        return Self.post(title: post.title, body: post.body?.plainText ?? "", manual: manual)
    }

    static func post(title: String, body: String, manual: Bool = false) -> Bool {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return manual }
        let count = (title + "\n" + body).unicodeScalars.count
        return manual || count >= postCharacterThreshold
    }

    static func comments(_ comments: [CommentSummaryInput.Comment], manual: Bool = false) -> Bool {
        let count = comments.reduce(into: 0) { $0 += $1.text.unicodeScalars.count }
        return manual || count >= commentCharacterThreshold
    }
}

/// Selects short source excerpts when the local model is unavailable. This is
/// intentionally deterministic and is never labelled as an AI summary.
enum DeterministicExcerptEngine {
    static func excerpts(
        title: String,
        body: String,
        maxSentences: Int = 4,
        maxCharacters: Int = 900
    ) -> [String] {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmedBody.isEmpty
            ? title.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedBody
        guard !source.isEmpty else { return [] }

        let titleTerms = terms(title)
        let sentences = sentenceRanges(in: source).map { range in
            let text = String(source[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let sentenceTerms = terms(text)
            let overlap = titleTerms.isEmpty ? 0 : sentenceTerms.intersection(titleTerms).count
            let position = source.distance(from: source.startIndex, to: range.lowerBound)
            let relativePosition = source.isEmpty ? 0 : 1 - Double(position) / Double(source.count)
            return Candidate(text: text, terms: sentenceTerms, score: Double(overlap * 3) + relativePosition)
        }
        .filter { !$0.text.isEmpty }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.text.count < rhs.text.count }
            return lhs.score > rhs.score
        }

        var selected: [Candidate] = []
        var usedCharacters = 0
        for candidate in sentences {
            guard selected.count < maxSentences else { break }
            guard candidate.text.count <= maxCharacters else { continue }
            let isRedundant = selected.contains { previous in
                let union = previous.terms.union(candidate.terms)
                guard !union.isEmpty else { return previous.text == candidate.text }
                let similarity = Double(previous.terms.intersection(candidate.terms).count) / Double(union.count)
                return similarity > 0.72
            }
            guard !isRedundant else { continue }
            guard usedCharacters + candidate.text.count <= maxCharacters || selected.isEmpty else { continue }
            selected.append(candidate)
            usedCharacters += candidate.text.count
        }
        return selected
            .sorted { lhs, rhs in
                let leftIndex = source.range(of: lhs.text)?.lowerBound ?? source.endIndex
                let rightIndex = source.range(of: rhs.text)?.lowerBound ?? source.endIndex
                return leftIndex < rightIndex
            }
            .map(\.text)
    }

    static func contentHash(title: String, body: String) -> String {
        let data = Data((title + "\n\u{001F}\n" + body).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Candidate {
        let text: String
        let terms: Set<String>
        let score: Double
    }

    private static func sentenceRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        if ranges.isEmpty { return [text.startIndex..<text.endIndex] }
        return ranges
    }

    private static func terms(_ value: String) -> Set<String> {
        Set(value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 })
    }
}

struct SummaryCacheKey: Hashable, Sendable {
    let contentHash: String
    let contentID: String
    let promptVersion: String
    let modelFamily: String
    let localeIdentifier: String

    init(contentID: String, title: String, body: String, promptVersion: String = "summary-v1", modelFamily: String = "system") {
        self.contentHash = DeterministicExcerptEngine.contentHash(title: title, body: body)
        self.contentID = contentID
        self.promptVersion = promptVersion
        self.modelFamily = modelFamily
        self.localeIdentifier = Locale.current.identifier
    }
}

actor InMemorySummaryCache {
    private struct Entry: Sendable {
        var summary: ContentSummary
        var lastUsedAt: Date
    }

    private var entries: [SummaryCacheKey: Entry] = [:]
    private let lifetime: TimeInterval
    private let capacity: Int

    init(lifetime: TimeInterval = 30 * 24 * 60 * 60, capacity: Int = 100) {
        self.lifetime = lifetime
        self.capacity = capacity
    }

    func value(for key: SummaryCacheKey, now: Date = .now) -> ContentSummary? {
        guard let entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.summary.generatedAt) <= lifetime else {
            entries.removeValue(forKey: key)
            return nil
        }
        entries[key]?.lastUsedAt = now
        return entry.summary
    }

    func insert(_ summary: ContentSummary, for key: SummaryCacheKey, now: Date = .now) {
        entries[key] = Entry(summary: summary, lastUsedAt: now)
        if entries.count > capacity {
            let removeCount = entries.count - capacity
            for key in entries.sorted(by: { $0.value.lastUsedAt < $1.value.lastUsedAt }).prefix(removeCount).map(\.key) {
                entries.removeValue(forKey: key)
            }
        }
    }

    func removeAll() { entries.removeAll() }

    func count() -> Int { entries.count }
}
