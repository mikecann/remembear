import Foundation

/// What the summariser writes back, and the Markdown file made from it. The
/// file follows Codex's Computer History layout (frontmatter with title,
/// description and applications, then "## Memory summary" and friends), so
/// Agent Archive and Codex's own memory step read it like one of theirs.
public struct SummaryDraft: Equatable, Sendable {
    public var title: String
    public var description: String
    public var body: String

    public init(title: String, description: String, body: String) {
        self.title = title
        self.description = description
        self.body = body
    }
}

public enum SummaryFile {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingTitle, missingDescription, missingBody

        public var description: String {
            switch self {
            case .missingTitle: "no TITLE: line"
            case .missingDescription: "no DESCRIPTION: line"
            case .missingBody: "no \"## Memory summary\" section"
            }
        }
    }

    /// Parses the model's reply:
    ///
    ///     TITLE: …
    ///     DESCRIPTION: …
    ///     ## Memory summary
    ///     …
    ///
    /// Asking for two labelled lines and plain Markdown is sturdier than JSON
    /// with a big escaped Markdown string inside it.
    public static func parseReply(_ reply: String) throws -> SummaryDraft {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        // Models sometimes wrap the whole reply in a code fence.
        if text.hasPrefix("```") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if let fence = text.range(of: "```", options: .backwards) { text = String(text[..<fence.lowerBound]) }
        }
        var title: String?
        var description: String?
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var bodyStart: Int?
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if title == nil, let v = value(trimmed, "TITLE:") { title = v; continue }
            if description == nil, let v = value(trimmed, "DESCRIPTION:") { description = v; continue }
            if trimmed.hasPrefix("## Memory summary") { bodyStart = i; break }
        }
        guard let title, !title.isEmpty else { throw ParseError.missingTitle }
        guard let description, !description.isEmpty else { throw ParseError.missingDescription }
        guard let bodyStart else { throw ParseError.missingBody }
        let body = lines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return SummaryDraft(title: oneLine(title, 120), description: oneLine(description, 600), body: body)
    }

    private static func value(_ line: String, _ label: String) -> String? {
        guard line.uppercased().hasPrefix(label) else { return nil }
        return String(line.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
    }

    public static func render(_ draft: SummaryDraft, applications: [String], citations: [String]) -> String {
        var out = "---\n"
        out += "title: \(yamlScalar(draft.title))\n"
        out += "description: \(yamlScalar(draft.description))\n"
        out += "applications: [\(applications.map(yamlScalar).joined(separator: ", "))]\n"
        out += "generator: recall-it\n"
        out += "---\n\n"
        out += draft.body
        if !citations.isEmpty {
            out += "\n\n## Citations\n\n" + citations.map { "- \($0)" }.joined(separator: "\n")
        }
        return out + "\n"
    }

    /// The body of a summary file, without its frontmatter.
    public static func body(of file: String) -> String {
        let lines = file.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return file }
        var body = lines[(end + 1)...].joined(separator: "\n")
        // Citations are file paths for provenance; they mean nothing to the model.
        if let cut = body.range(of: "\n## Citations") { body = String(body[..<cut.lowerBound]) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func title(of file: String) -> String? {
        for line in file.split(separator: "\n").prefix(20) where line.hasPrefix("title:") {
            var v = line.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            return v
        }
        return nil
    }

    static func oneLine(_ s: String, _ max: Int) -> String {
        var flat = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if flat.count >= 2, flat.first == "\"", flat.last == "\"" { flat = String(flat.dropFirst().dropLast()) }
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    /// Plain when that's valid YAML, else double-quoted. Agent Archive's
    /// parser strips outer quotes but doesn't unescape, so inner double quotes
    /// become single quotes rather than \".
    static func yamlScalar(_ s: String) -> String {
        let special = CharacterSet(charactersIn: ":#{}[],&*?|<>=!%@`\"'")
        let needsQuotes = s.isEmpty || s.contains(": ") || s.contains(" #") || s.hasSuffix(":")
            || s.unicodeScalars.first.map { special.contains($0) || $0 == "-" } ?? true
        guard needsQuotes else { return s }
        return "\"" + s.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "\"", with: "'") + "\""
    }
}
