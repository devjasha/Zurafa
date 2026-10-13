import Foundation

/// Converts Emacs Org markup to Markdown so the preview can reuse its Markdown renderer.
/// shortcut: covers headings, blocks, lists, tables, links and emphasis; no footnotes, macros or LaTeX.
enum OrgMarkdown {
    static func convert(_ org: String) -> String {
        var out: [String] = []
        var fence = false, quote = false, drawer = false
        for line in org.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let keyword = trimmed.lowercased()
            if fence {
                if keyword.hasPrefix("#+end_src") || keyword.hasPrefix("#+end_example") { fence = false; out.append("```") }
                else { out.append(line) }
                continue
            }
            if drawer {
                if keyword == ":end:" { drawer = false }
                continue
            }
            if keyword.hasPrefix("#+begin_src") || keyword.hasPrefix("#+begin_example") {
                let language = keyword.hasPrefix("#+begin_src") ? trimmed.split(separator: " ").dropFirst().first.map(String.init) ?? "" : ""
                fence = true
                out.append("```" + language)
            } else if keyword.hasPrefix("#+begin_quote") {
                quote = true
            } else if keyword.hasPrefix("#+end_quote") {
                quote = false
            } else if keyword.hasPrefix("#+title:") {
                out.append("# " + inline(String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("#+") || trimmed == "#" || trimmed.hasPrefix("# ") {
                continue // Other keywords and comments are not rendered.
            } else if trimmed.range(of: #"^:[A-Za-z_]+:$"#, options: .regularExpression) != nil {
                drawer = true
            } else if let stars = line.range(of: #"^\*+ "#, options: .regularExpression) {
                let level = min(line.distance(from: stars.lowerBound, to: stars.upperBound) - 1, 6)
                out.append(String(repeating: "#", count: level) + " " + inline(String(line[stars.upperBound...])))
            } else if trimmed.hasPrefix("|") {
                // Org rule rows (|---+---|) become Markdown header separators.
                out.append(trimmed.hasPrefix("|-") ? trimmed.replacingOccurrences(of: "+", with: "|") : inline(trimmed))
            } else {
                out.append((quote ? "> " : "") + inline(line.replacingOccurrences(of: #"^(\s*)\+ "#, with: "$1- ", options: .regularExpression)))
            }
        }
        return out.joined(separator: "\n")
    }

    static func inline(_ text: String) -> String {
        var s = text
        for (mark, open, close) in [("=", "`", "`"), ("~", "`", "`"), ("\\*", "**", "**"), ("/", "*", "*"), ("\\+", "~~", "~~")] {
            let pattern = "(?<=^|[\\s(\"'{-])\(mark)([^\\s\(mark)](?:[^\(mark)\\n]*[^\\s\(mark)])?)\(mark)(?=$|[\\s.,:;!?'\")}\\]-])"
            s = s.replacingOccurrences(of: pattern, with: "\(open)$1\(close)", options: .regularExpression)
        }
        // [[target][description]] and [[target]]; file: links stay relative to the previewed file.
        s = s.replacingOccurrences(of: #"\[\[(?:file:)?([^\]]+)\]\[([^\]]+)\]\]"#, with: "[$2](<$1>)", options: .regularExpression)
        return s.replacingOccurrences(of: #"\[\[(?:file:)?([^\]]+)\]\]"#, with: "[$1](<$1>)", options: .regularExpression)
    }
}
