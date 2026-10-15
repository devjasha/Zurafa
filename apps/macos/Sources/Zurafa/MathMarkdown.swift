import AppKit
import MarkdownUI
import SwiftMath
import SwiftUI

/// Pulls LaTeX math out of Markdown before it is parsed (Markdown would eat the `\[` escapes)
/// and leaves `![](zurafa-math:N)` image links that `MathImageProvider` draws with SwiftMath.
/// shortcut: no `\newcommand`/`\def` macros; add a substitution pass if notes start relying on them.
enum MathMarkdown {
    static let scheme = "zurafa-math"

    // Code is matched first and kept as is, so `$` inside code never turns into math.
    private static let pattern = try! NSRegularExpression(pattern: [
        #"(?<code>```[\s\S]*?(?:```|$(?![\s\S]))|`[^`\n]*`)"#,
        #"\$\$(?<dollars>[\s\S]+?)\$\$"#,
        #"\\\[(?<brackets>[\s\S]+?)\\\]"#,
        #"\\begin\{(?<env>equation|align|gather)(?<star>\*?)\}(?<body>[\s\S]+?)\\end\{\k<env>\*?\}"#,
        #"\\\((?<parens>[\s\S]+?)\\\)"#,
        // Pandoc's rule: no space inside the dollars and no digit after, so "$5 and $10" stays text.
        #"(?<![\\$\w])\$(?<inline>[^\s$](?:[^$\n]*[^\s$\\])?)\$(?![\d$])"#,
    ].joined(separator: "|"), options: [.anchorsMatchLines])

    static func extract(_ text: String) -> (markdown: String, formulas: [String]) {
        let ns = text as NSString
        var out = "", formulas: [String] = [], cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            func group(_ name: String) -> String? {
                let range = match.range(withName: name)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            if let code = group("code") { out += code; continue }
            let display: Bool, latex: String
            if let body = group("body") {
                display = true
                latex = group("env") == "equation" ? body : "\\begin{aligned}\(body)\\end{aligned}"
            } else if let inline = group("parens") ?? group("inline") {
                display = false; latex = inline
            } else {
                display = true; latex = group("dollars") ?? group("brackets") ?? ""
            }
            let link = "![](\(scheme):\(display ? "display" : "inline")/\(formulas.count))"
            formulas.append(latex.trimmingCharacters(in: .whitespacesAndNewlines))
            // A display formula alone in its paragraph is drawn as a block by MarkdownUI.
            out += display ? "\n\n\(link)\n\n" : link
        }
        out += ns.substring(from: cursor)
        return (out, formulas)
    }

    /// The formula behind a `zurafa-math:` link, or nil for every other image.
    static func formula(_ url: URL?, in formulas: [String]) -> (latex: String, display: Bool)? {
        guard let url, url.scheme == scheme else { return nil }
        let parts = url.absoluteString.dropFirst(scheme.count + 1).split(separator: "/")
        guard parts.count == 2, let index = Int(parts[1]), formulas.indices.contains(index) else { return nil }
        return (formulas[index], parts[0] == "display")
    }

    static func image(_ formula: (latex: String, display: Bool), fontSize: CGFloat, color: NSColor) -> NSImage? {
        MTMathImage(latex: formula.latex, fontSize: formula.display ? fontSize * 1.15 : fontSize, textColor: color,
                    labelMode: formula.display ? .display : .text, textAlignment: .left).asImage().1
    }
}

struct MathImageProvider: ImageProvider {
    let formulas: [String]
    let fontSize: CGFloat
    let color: NSColor

    @ViewBuilder func makeImage(url: URL?) -> some View {
        if let formula = MathMarkdown.formula(url, in: formulas) {
            Group {
                if let image = MathMarkdown.image(formula, fontSize: fontSize, color: color) {
                    ScrollView(.horizontal, showsIndicators: false) { Image(nsImage: image) }
                } else {
                    Text(formula.latex).font(.system(.body, design: .monospaced)) // unparsable: show the source
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        } else {
            DefaultImageProvider.default.makeImage(url: url)
        }
    }
}

struct MathInlineImageProvider: InlineImageProvider {
    let formulas: [String]
    let fontSize: CGFloat
    let color: NSColor

    func image(with url: URL, label: String) async throws -> Image {
        guard let formula = MathMarkdown.formula(url, in: formulas) else { return try await DefaultInlineImageProvider.default.image(with: url, label: label) }
        guard let image = await MainActor.run(body: { MathMarkdown.image(formula, fontSize: fontSize, color: color) }) else {
            throw URLError(.cannotDecodeContentData)
        }
        return Image(nsImage: image)
    }
}
