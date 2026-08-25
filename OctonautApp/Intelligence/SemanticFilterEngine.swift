import Foundation
import CryptoKit

struct KeywordFilterRule: Sendable, Hashable {
    var terms: [String]
    var fields: Set<KeywordFilterField>
    var wholeWord: Bool
    var caseSensitive: Bool

    init(
        terms: [String],
        fields: Set<KeywordFilterField> = Set(KeywordFilterField.allCases),
        wholeWord: Bool = false,
        caseSensitive: Bool = false
    ) {
        self.terms = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.fields = fields
        self.wholeWord = wholeWord
        self.caseSensitive = caseSensitive
    }
}

enum KeywordFilterField: String, CaseIterable, Hashable, Sendable {
    case title
    case author
    case community
    case selfText
    case linkDescription
}

struct DeterministicFilterConfiguration: Sendable, Hashable {
    var blockedCommunities: Set<String>
    var keywordRules: [KeywordFilterRule]
    var seenPostIDs: Set<String>
    var hideSeen: Bool

    init(
        blockedCommunities: Set<String> = [],
        keywordRules: [KeywordFilterRule] = [],
        seenPostIDs: Set<String> = [],
        hideSeen: Bool = false
    ) {
        self.blockedCommunities = Set(blockedCommunities.map(IDNormalization.community))
        self.keywordRules = keywordRules
        self.seenPostIDs = seenPostIDs
        self.hideSeen = hideSeen
    }
}

struct DeterministicFilterResult: Sendable, Hashable {
    let visible: [Post]
    let removedCount: Int
    let reasons: [String: Int]
}

enum DeterministicPostFilter {
    static func apply(_ posts: [Post], configuration: DeterministicFilterConfiguration) -> DeterministicFilterResult {
        var visible: [Post] = []
        var reasons: [String: Int] = [:]
        for post in posts {
            let community = IDNormalization.community(post.community.name)
            if configuration.blockedCommunities.contains(community) {
                reasons["Community"] = (reasons["Community"] ?? 0) + 1
                continue
            }
            if configuration.hideSeen && configuration.seenPostIDs.contains(post.id) {
                reasons["Seen"] = (reasons["Seen"] ?? 0) + 1
                continue
            }
            if configuration.keywordRules.contains(where: { matches(post, rule: $0) }) {
                reasons["Keyword"] = (reasons["Keyword"] ?? 0) + 1
                continue
            }
            visible.append(post)
        }
        return DeterministicFilterResult(visible: visible, removedCount: posts.count - visible.count, reasons: reasons)
    }

    private static func matches(_ post: Post, rule: KeywordFilterRule) -> Bool {
        let fields: [KeywordFilterField: String] = [
            .title: post.title,
            .author: post.author?.username ?? "",
            .community: post.community.name,
            .selfText: post.body?.plainText ?? "",
            .linkDescription: post.media.primaryURL?.absoluteString ?? ""
        ]
        return rule.terms.contains { term in
            rule.fields.contains { field in
                guard let value = fields[field] else { return false }
                return matchesTerm(term, in: value, wholeWord: rule.wholeWord, caseSensitive: rule.caseSensitive)
            }
        }
    }

    private static func matchesTerm(_ term: String, in value: String, wholeWord: Bool, caseSensitive: Bool) -> Bool {
        guard !term.isEmpty else { return false }
        let source = caseSensitive ? value : value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let needle = caseSensitive ? term : term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard wholeWord else { return source.localizedStandardContains(needle) }
        let escaped = NSRegularExpression.escapedPattern(for: needle)
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])", options: caseSensitive ? [] : [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
    }
}

actor SemanticFilterEngine {
    private let service: any IntelligenceService
    private var cache: [SemanticFilterCacheKey: FilterDecision] = [:]
    private let promptVersion = "semantic-filter-v1"

    init(service: any IntelligenceService) {
        self.service = service
    }

    func classify(posts: [Post], rule: SemanticRule, batchSize: Int = 12) async -> [FilterDecision] {
        guard !posts.isEmpty else { return [] }
        let inputs = posts.map { post in
            FilterInput(
                id: post.id,
                title: post.title,
                community: post.community.name,
                text: String((post.body?.plainText ?? post.media.primaryURL?.absoluteString ?? "").prefix(500))
            )
        }
        var results: [FilterDecision] = []
        for batch in stride(from: 0, to: inputs.count, by: max(1, batchSize)) {
            let end = min(batch + max(1, batchSize), inputs.count)
            let part = Array(inputs[batch..<end])
            let uncached = part.filter { cache[cacheKey(for: $0, rule: rule)] == nil }
            var decisions = part.compactMap { cache[cacheKey(for: $0, rule: rule)] }
            if !uncached.isEmpty {
                do {
                    let generated = try await service.classify(uncached, rule: rule)
                    let expected = Set(uncached.map(\.id))
                    let actual = generated.map(\.itemID)
                    guard actual.count == expected.count, Set(actual) == expected else { continue }
                    for decision in generated {
                        cache[cacheKey(for: uncached.first { $0.id == decision.itemID }!, rule: rule)] = decision
                    }
                    decisions.append(contentsOf: generated)
                } catch {
                    // A failed or unavailable model leaves these posts visible.
                    continue
                }
            }
            let byID = Dictionary(uniqueKeysWithValues: decisions.map { ($0.itemID, $0) })
            results.append(contentsOf: part.compactMap { byID[$0.id] })
        }
        return results
    }

    func clearCache() { cache.removeAll() }

    private func cacheKey(for input: FilterInput, rule: SemanticRule) -> SemanticFilterCacheKey {
        SemanticFilterCacheKey(
            postID: input.id,
            contentHash: SHA256.hash(data: Data("\(input.title)\n\(input.community)\n\(input.text)".utf8)).map { String(format: "%02x", $0) }.joined(),
            ruleID: rule.id,
            ruleRevision: rule.revision,
            instructionHash: SHA256.hash(data: Data(rule.instruction.utf8)).map { String(format: "%02x", $0) }.joined(),
            promptVersion: promptVersion
        )
    }
}

private struct SemanticFilterCacheKey: Hashable, Sendable {
    let postID: String
    let contentHash: String
    let ruleID: String
    let ruleRevision: Int
    let instructionHash: String
    let promptVersion: String
}
