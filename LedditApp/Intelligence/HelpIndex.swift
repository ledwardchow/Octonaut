import Foundation
import Observation

struct HelpSearchResult: Identifiable, Hashable, Sendable {
    let section: HelpSection
    let score: Double
    var id: String { section.id }
}

/// A small lexical index that works offline. It uses title weighting, term
/// coverage, phrase matches, and a BM25-like frequency score.
struct LocalHelpIndex: Sendable {
    let version: String
    let sections: [HelpSection]

    init(version: String = "help-v1", sections: [HelpSection] = LocalHelpIndex.defaultSections) {
        self.version = version
        self.sections = sections
    }

    func search(_ query: String, limit: Int = 6) -> [HelpSearchResult] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return Array(sections.prefix(limit)).map { HelpSearchResult(section: $0, score: 0) } }
        let queryTerms = tokenize(normalizedQuery)
        guard !queryTerms.isEmpty else { return [] }
        return sections.compactMap { section in
            let titleTerms = tokenize(section.title)
            let bodyTerms = tokenize(section.text)
            let titleMatches = queryTerms.filter { titleTerms.contains($0) }.count
            let bodyMatches = queryTerms.filter { bodyTerms.contains($0) }.count
            let termFrequency = queryTerms.reduce(0) { partial, term in
                partial + bodyTerms.filter { $0 == term }.count
            }
            let coverage = Double(Set(queryTerms).intersection(bodyTerms).count) / Double(Set(queryTerms).count)
            let phraseBonus = section.title.localizedCaseInsensitiveContains(normalizedQuery) ? 12.0 : 0
            let score = Double(titleMatches * 8 + bodyMatches * 2) + min(Double(termFrequency), 8) + coverage * 10 + phraseBonus
            return score > 0 ? HelpSearchResult(section: section, score: score) : nil
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.section.id < rhs.section.id }
            return lhs.score > rhs.score
        }
        .prefix(limit)
        .map { $0 }
    }

    private func tokenize(_ value: String) -> [String] {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 }
    }

    static let defaultSections: [HelpSection] = [
        HelpSection(id: "getting-started", title: "Getting Started", text: "Leddit is a native Reddit reader for iPhone and iPad. Use Posts to browse Home, Popular, All, and community feeds. Search uses Reddit only after you submit a query. Feed content can be read offline after it has been cached."),
        HelpSection(id: "accounts-login", title: "Accounts and Login", text: "Leddit signs into Reddit's website inside a temporary private web view. It never reads your password. The resulting session is stored in the device-only Keychain. Each saved account has its own session and account-scoped data."),
        HelpSection(id: "reading", title: "Reading", text: "Tap a post to open its detail screen. Swipe or use the context menu to vote, save, share, or mark a post seen. Spoilers and NSFW media require a reveal when those settings are enabled."),
        HelpSection(id: "posting", title: "Posting", text: "Use the compose button to create a text post, link post, comment, reply, edit, or message. Drafts are saved on the device and are tied to the selected account. A failed send keeps the draft."),
        HelpSection(id: "gestures", title: "Gestures", text: "The default post actions are short right swipe for upvote, long right swipe for downvote, short left swipe for mark seen, and long left swipe for save. Comments use reply for short left swipe. Every gesture has a context-menu equivalent."),
        HelpSection(id: "filters", title: "Filters", text: "Keyword and community filters run locally. Semantic rules use Apple's on-device language model when it is available. A paused semantic rule never hides posts. Disable a rule from the filter settings if it makes a mistake."),
        HelpSection(id: "on-device-intelligence", title: "On-device Intelligence", text: "Post and comment summaries are generated on device from the selected visible text. They may be wrong, are shown separately from Reddit content, and do not use a hosted model. If Apple Intelligence is unavailable, Leddit can show deterministic Key excerpts instead."),
        HelpSection(id: "privacy", title: "Privacy", text: "Leddit has no analytics SDK, hosted AI service, developer-operated account service, or release-one push server. Reddit requests still disclose normal network information to Reddit and media hosts. Clear local content from Settings."),
        HelpSection(id: "troubleshooting", title: "Troubleshooting", text: "If a feed does not load, check the network connection and try again. Reddit can rate limit or change its web JSON responses. Unsupported content keeps an Open Original link. A model that is downloading or disabled will show its availability reason."),
        HelpSection(id: "reddit-limitations", title: "Known Reddit Limitations", text: "The initial authenticated transport uses a Reddit web session rather than official OAuth. Reddit may change cookie names, routes, response fields, anti-bot checks, or permitted use. Logged-out reading remains available when account access fails.")
    ]
}

@MainActor
@Observable
final class HelpAssistantModel {
    let index: LocalHelpIndex
    private let intelligence: any IntelligenceService
    var query = ""
    var results: [HelpSearchResult] = []
    var answer: HelpAnswer?
    var errorMessage: String?
    var isAnswering = false

    init(index: LocalHelpIndex = LocalHelpIndex(), intelligence: any IntelligenceService) {
        self.index = index
        self.intelligence = intelligence
        results = index.search("")
    }

    func search() {
        results = index.search(query)
        answer = nil
        errorMessage = nil
    }

    func answerQuestion() async {
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let selected = results.isEmpty ? index.search(question) : results
        guard !selected.isEmpty else {
            errorMessage = "No help section matches that question yet."
            return
        }
        isAnswering = true
        errorMessage = nil
        defer { isAnswering = false }
        do {
            answer = try await intelligence.answerHelp(question, sections: selected.map(\.section))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
