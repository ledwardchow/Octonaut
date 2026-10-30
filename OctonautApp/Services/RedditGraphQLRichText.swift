import Foundation

enum RedditGraphQLRichText {
    static func decode(_ content: [String: RedditJSONValue], thingID: String) -> RichText? {
        if let markdown = content["markdown"]?.stringValue, !markdown.isEmpty {
            return RichText(plainText: markdown)
        }
        let rich: [String: RedditJSONValue]?
        if let object = content["richtext"]?.objectValue {
            rich = object
        } else if let string = content["richtext"]?.stringValue {
            rich = try? JSONDecoder().decode([String: RedditJSONValue].self, from: Data(string.utf8))
        } else {
            rich = nil
        }
        guard let document = rich?["document"]?.arrayValue else {
            return content["markdown"]?.stringValue.map { RichText(plainText: $0) }
        }
        let shortID = thingID.hasPrefix("t1_") || thingID.hasPrefix("t3_") ? String(thingID.dropFirst(3)) : thingID
        let renderer = Renderer(media: content["richtextMedia"]?.arrayValue ?? [], thingID: shortID)
        return RichText(plainText: renderer.blocks(document))
    }

    private struct Renderer {
        let media: [RedditJSONValue]
        let thingID: String

        func blocks(_ values: [RedditJSONValue]) -> String {
            values.compactMap { value -> String? in
                guard let node = value.objectValue else { return nil }
                switch node["e"]?.stringValue {
                case "par": return inline(node["c"]?.arrayValue ?? [])
                case "h":
                    let level = min(max(Int(node["l"]?.numberValue ?? 1), 1), 6)
                    return String(repeating: "#", count: level) + " " + inline(node["c"]?.arrayValue ?? [])
                case "blockquote":
                    return blocks(node["c"]?.arrayValue ?? []).split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "> " + $0 }.joined(separator: "\n")
                case "list":
                    let ordered = node["o"]?.boolValue == true
                    return (node["c"]?.arrayValue ?? []).enumerated().compactMap { index, item -> String? in
                        guard let child = item.objectValue else { return nil }
                        let contents = child["c"]?.arrayValue ?? []
                        let text: String
                        if contents.count == 1, contents[0].objectValue?["e"]?.stringValue == "par" {
                            text = inline(contents[0].objectValue?["c"]?.arrayValue ?? [])
                        } else {
                            text = blocks(contents)
                        }
                        let prefix = ordered ? "\(index + 1). " : "- "
                        return prefix + text.replacingOccurrences(of: "\n", with: "\n  ")
                    }.joined(separator: "\n")
                case "li": return blocks(node["c"]?.arrayValue ?? [])
                case "code":
                    let lines = node["c"]?.arrayValue?.compactMap { $0.objectValue?["t"]?.stringValue } ?? []
                    let code = lines.joined(separator: "\n")
                    let fence = String(repeating: "`", count: max(3, longestBacktickRun(code) + 1))
                    return "\(fence)\n\(code)\n\(fence)"
                case "table": return table(node)
                case "img", "gif", "video": return mediaMarkdown(node)
                case "hr": return "---"
                default:
                    if let children = node["c"]?.arrayValue { return inline(children) }
                    return escaped(node["t"]?.stringValue ?? "")
                }
            }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }

        func inline(_ values: [RedditJSONValue]) -> String {
            values.compactMap { value -> String? in
                guard let node = value.objectValue else { return nil }
                switch node["e"]?.stringValue {
                case "text": return formatted(node)
                case "link":
                    let label = formatted(node)
                    guard let target = safeURL(node["u"]?.stringValue) else { return label }
                    return "[\(label)](\(target.absoluteString.replacingOccurrences(of: ")", with: "%29")))"
                case "r/", "u/":
                    let name = (node["e"]?.stringValue ?? "") + (node["t"]?.stringValue ?? "")
                    return "[\(node["l"]?.boolValue == true ? "/" : "")\(escaped(name))](https://www.reddit.com/\(name))"
                case "spoilertext": return ">!\(inline(node["c"]?.arrayValue ?? []))!<"
                case "br": return "  \n"
                case "img", "gif", "video": return mediaMarkdown(node)
                default: return escaped(node["t"]?.stringValue ?? "")
                }
            }.joined()
        }

        func formatted(_ node: [String: RedditJSONValue]) -> String {
            let characters = Array((node["t"]?.stringValue ?? "").unicodeScalars).map(String.init)
            guard !characters.isEmpty else { return "" }
            var flags = Array(repeating: 0, count: characters.count)
            for format in node["f"]?.arrayValue ?? [] {
                guard let parts = format.arrayValue, parts.count >= 3,
                      let bits = parts[0].numberValue.map(Int.init),
                      let offset = parts[1].numberValue.map(Int.init),
                      let length = parts[2].numberValue.map(Int.init),
                      offset >= 0, length > 0, offset <= characters.count,
                      length <= characters.count - offset else { continue }
                for index in offset..<(offset + length) { flags[index] |= bits }
            }
            var result = ""
            var start = 0
            while start < characters.count {
                var end = start + 1
                while end < characters.count && flags[end] == flags[start] { end += 1 }
                let raw = characters[start..<end].joined()
                let bits = flags[start]
                var part = escaped(raw)
                if bits & 64 != 0 { part = "`\(raw.replacingOccurrences(of: "`", with: "\\`"))`" }
                if bits & 8 != 0 { part = "~~\(part)~~" }
                if bits & 2 != 0 { part = "*\(part)*" }
                if bits & 1 != 0 { part = "**\(part)**" }
                result += part
                start = end
            }
            return result
        }

        func table(_ node: [String: RedditJSONValue]) -> String {
            let headers = node["h"]?.arrayValue ?? []
            guard !headers.isEmpty else { return "" }
            let head = headers.map { cell in inline(cell.objectValue?["c"]?.arrayValue ?? []).replacingOccurrences(of: "|", with: "\\|") }
            let alignment = headers.map { cell -> String in
                switch cell.objectValue?["a"]?.stringValue {
                case "C": return ":---:"
                case "R": return "---:"
                default: return "---"
                }
            }
            let rows = (node["c"]?.arrayValue ?? []).map { row in
                let cells = row.arrayValue ?? []
                return "| " + cells.map { cell in inline(cell.objectValue?["c"]?.arrayValue ?? []).replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
            }
            return (["| " + head.joined(separator: " | ") + " |", "| " + alignment.joined(separator: " | ") + " |"] + rows).joined(separator: "\n")
        }

        func mediaMarkdown(_ node: [String: RedditJSONValue]) -> String {
            guard let id = node["id"]?.stringValue else { return "" }
            if node["e"]?.stringValue == "video" {
                let url = "https://reddit.com/link/\(thingID)/video/\(id)/player"
                return "[Video](\(url))"
            }
            if id.hasPrefix("giphy|"), let gifID = id.split(separator: "|").dropFirst().first {
                return "[giphy](https://giphy.com/gifs/\(gifID))"
            }
            let entry = media.first { $0.objectValue?["id"]?.stringValue == id }?.objectValue
            let source = ["xxxlarge", "xxlarge", "xlarge", "large", "medium"].compactMap {
                entry?[$0]?.objectValue?["url"]?.stringValue
            }.first ?? entry?["url"]?.stringValue
            guard let url = safeURL(source) else { return "" }
            return "![Image](\(url.absoluteString.replacingOccurrences(of: ")", with: "%29")))"
        }

        func safeURL(_ source: String?) -> URL? {
            guard let source, let url = URL(string: source),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }

        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "_", with: "\\_")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
                .replacingOccurrences(of: "`", with: "\\`")
        }

        func longestBacktickRun(_ value: String) -> Int {
            value.split(separator: "`", omittingEmptySubsequences: false).count - 1
        }
    }
}
