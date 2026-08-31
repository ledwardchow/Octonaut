import SwiftUI

struct RedditMarkdownTable: Equatable {
    let headers: [String]
    let rows: [[String]]
}

struct RedditMarkdownImage: Equatable {
    let url: URL
    let altText: String?
}

enum RedditMarkdownBlock: Equatable {
    case text(String)
    case table(RedditMarkdownTable)
    case image(RedditMarkdownImage)
}

struct RedditMarkdownView: View {
    let source: String

    private var blocks: [RedditMarkdownBlock] {
        RedditPostMarkdown.blocks(from: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(RedditPostMarkdown.attributedString(from: text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .table(let table):
                    RedditMarkdownTableView(table: table)
                case .image(let image):
                    RedditMarkdownImageView(image: image)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RedditMarkdownImageView: View {
    let image: RedditMarkdownImage

    var body: some View {
        Link(destination: image.url) {
            AsyncImage(url: image.url) { phase in
                switch phase {
                case .empty:
                    ZStack {
                        Color.secondary.opacity(0.08)
                        ProgressView()
                    }
                    .frame(height: 180)
                case .success(let loadedImage):
                    loadedImage
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 520, alignment: .leading)
                case .failure:
                    Label(image.altText ?? image.url.absoluteString, systemImage: "photo")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                @unknown default:
                    EmptyView()
                }
            }
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(image.altText ?? "Linked Reddit image")
        .accessibilityHint("Opens the image")
    }
}

private struct RedditMarkdownTableView: View {
    let table: RedditMarkdownTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(table.headers.indices, id: \.self) { index in
                        cell(table.headers[index], isHeader: true)
                    }
                }
                ForEach(table.rows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(table.headers.indices, id: \.self) { columnIndex in
                            cell(value(at: columnIndex, in: table.rows[rowIndex]))
                        }
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .scrollIndicators(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table with \(table.headers.count) columns and \(table.rows.count) rows")
    }

    private func value(at index: Int, in row: [String]) -> String {
        row.indices.contains(index) ? row[index] : ""
    }

    private func cell(_ source: String, isHeader: Bool = false) -> some View {
        Text(RedditPostMarkdown.attributedString(from: source))
            .fontWeight(isHeader ? .semibold : .regular)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 88, maxWidth: 180, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isHeader ? Color.secondary.opacity(0.14) : Color.clear)
            .overlay {
                Rectangle().stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
            }
    }
}

/// Converts the Markdown returned by Reddit into text SwiftUI can render on every platform.
enum RedditPostMarkdown {
    static func blocks(from source: String) -> [RedditMarkdownBlock] {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var result: [RedditMarkdownBlock] = []
        var textLines: [String] = []
        var index = 0

        func flushText() {
            guard !textLines.isEmpty else { return }
            result.append(.text(textLines.joined(separator: "\n")))
            textLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            guard index + 1 < lines.count,
                  let headers = tableCells(in: lines[index]),
                  headers.count >= 2,
                  isTableSeparator(lines[index + 1], expectedColumns: headers.count) else {
                textLines.append(lines[index])
                index += 1
                continue
            }

            flushText()
            index += 2
            var rows: [[String]] = []
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  let cells = tableCells(in: lines[index]),
                  cells.count >= 2 {
                rows.append(cells)
                index += 1
            }
            result.append(.table(RedditMarkdownTable(headers: headers, rows: rows)))
        }
        flushText()
        return result.flatMap(expandingImageLinks(in:))
    }

    private static func expandingImageLinks(
        in block: RedditMarkdownBlock
    ) -> [RedditMarkdownBlock] {
        guard case .text(let source) = block else { return [block] }

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var expanded: [RedditMarkdownBlock] = []
        var activeFence: Fence?

        for (index, line) in lines.enumerated() {
            let lineWithSeparator = index < lines.count - 1 ? line + "\n" : line
            if let fence = activeFence {
                appendText(lineWithSeparator, to: &expanded)
                if isClosingFence(line, matching: fence) {
                    activeFence = nil
                }
            } else if let fence = openingFence(in: line) {
                appendText(lineWithSeparator, to: &expanded)
                activeFence = fence
            } else {
                appendImageLinks(in: lineWithSeparator, to: &expanded)
            }
        }
        return expanded
    }

    private static func appendImageLinks(
        in source: String,
        to blocks: inout [RedditMarkdownBlock]
    ) {
        guard let expression = try? NSRegularExpression(
            pattern: #"!?\[([^\]\r\n]*)\]\((https://[^)\s]+)\)|https://[^\s<>()]+"#
        ) else {
            appendText(source, to: &blocks)
            return
        }

        let sourceRange = NSRange(source.startIndex..., in: source)
        var cursor = source.startIndex
        for match in expression.matches(in: source, range: sourceRange) {
            guard let matchRange = Range(match.range, in: source) else { continue }
            let rawURL: String
            let altText: String?
            if match.range(at: 2).location != NSNotFound,
               let urlRange = Range(match.range(at: 2), in: source) {
                rawURL = String(source[urlRange])
                altText = Range(match.range(at: 1), in: source).map {
                    String(source[$0]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else {
                rawURL = String(source[matchRange]).trimmingCharacters(in: trailingURLPunctuation)
                altText = nil
            }

            guard let url = redditImageURL(from: rawURL) else { continue }
            appendText(String(source[cursor..<matchRange.lowerBound]), to: &blocks)
            blocks.append(.image(RedditMarkdownImage(
                url: url,
                altText: altText?.isEmpty == false ? altText : nil
            )))
            cursor = source.index(matchRange.lowerBound, offsetBy: rawURL.count)
            if match.range(at: 2).location != NSNotFound {
                cursor = matchRange.upperBound
            }
        }
        appendText(String(source[cursor...]), to: &blocks)
    }

    private static func appendText(
        _ text: String,
        to blocks: inout [RedditMarkdownBlock]
    ) {
        guard !text.isEmpty else { return }
        if case .text(let existing) = blocks.last {
            blocks[blocks.count - 1] = .text(existing + text)
        } else {
            blocks.append(.text(text))
        }
    }

    private static let trailingURLPunctuation = CharacterSet(charactersIn: ".,;:!?")

    private static func redditImageURL(from source: String) -> URL? {
        let decoded = source.replacingOccurrences(of: "&amp;", with: "&")
        guard let url = URL(string: decoded), url.scheme?.lowercased() == "https" else {
            return nil
        }
        let imageHosts: Set<String> = ["i.redd.it", "preview.redd.it", "external-preview.redd.it"]
        if let host = url.host?.lowercased(), imageHosts.contains(host) {
            return url
        }

        guard let host = url.host?.lowercased(),
              (host == "reddit.com" || host.hasSuffix(".reddit.com")),
              url.path == "/media",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let nestedURL = components.queryItems?.first(where: { $0.name == "url" })?.value else {
            return nil
        }
        return redditImageURL(from: nestedURL)
    }

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
                renderedLines.append(renderLine(lines[index] + " " + lines[index + 1]))
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
                renderedLines.append(renderLine(lines[index]))
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

    private static func renderLine(_ source: String) -> AttributedString {
        let content = insertingMissingLinkSpacing(in: source)
        let trimmed = content.drop(while: { $0 == " " })
        let indentation = content.count - trimmed.count
        if trimmed.hasPrefix(">!"), trimmed.hasSuffix("!<") {
            return renderInline(String(trimmed.dropFirst(2).dropLast(2)))
        }
        if indentation <= 3, trimmed.first == ">" {
            let quote = trimmed.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
            return renderInline("▎ " + String(quote))
        }
        if let marker = trimmed.first,
           marker == "-" || marker == "+" || marker == "*",
           trimmed.dropFirst().first == " " || trimmed.dropFirst().first == "\t" {
            let item = trimmed.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
            return renderInline(
                String(repeating: " ", count: indentation) + "• " + String(item)
            )
        }
        return renderInline(content)
    }

    private static func renderInline(_ source: String, headingLevel: Int? = nil) -> AttributedString {
        let source = source.replacingOccurrences(
            of: #">!([^\n]+?)!<"#,
            with: "$1",
            options: .regularExpression
        )
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

    private static func tableCells(in line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var content = trimmed
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        return content
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String, expectedColumns: Int) -> Bool {
        guard let cells = tableCells(in: line), cells.count == expectedColumns else {
            return false
        }
        return cells.allSatisfy { cell in
            let marker = cell.trimmingCharacters(in: .whitespaces)
            return marker.contains("-") && marker.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }
}
