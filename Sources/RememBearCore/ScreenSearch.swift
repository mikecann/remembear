import Foundation

/// Screenshot search: each recorded capture's EmbeddingGemma 2 vector, kept
/// with what it was (time, app, window, a little of its masked text), so a
/// question in words finds the moments that looked like it.
public enum ScreenSearch {
    /// How long a capture stays searchable. Raw events go after 48 hours;
    /// vectors last longer as they hold no picture and only a short excerpt.
    public static let keepDays = 30
    public static let excerptLength = 400

    public struct Shot: Equatable, Sendable {
        public var at: Date
        public var app: String
        public var bundleID: String
        public var title: String?
        public var url: String?
        public var excerpt: String?
        public var vector: [Float]

        public init(at: Date, app: String, bundleID: String, title: String?, url: String?, excerpt: String?, vector: [Float]) {
            self.at = at
            self.app = app
            self.bundleID = bundleID
            self.title = title
            self.url = url
            self.excerpt = excerpt
            self.vector = vector
        }
    }

    public struct Hit: Equatable, Sendable {
        public var shot: Shot
        public var score: Float
    }

    /// The first part of a capture's (already masked) text, on one line.
    public static func excerpt(of text: String) -> String? {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " · ")
        guard !flat.isEmpty else { return nil }
        return flat.count > excerptLength ? String(flat.prefix(excerptLength - 1)) + "…" : flat
    }

    /// Float32s, little-endian, as stored in the database.
    public static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for f in vector { withUnsafeBytes(of: f.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    public static func decode(_ data: Data) -> [Float] {
        guard data.count % 4 == 0 else { return [] }
        return stride(from: 0, to: data.count, by: 4).map { i in
            let bits = data[data.startIndex + i ..< data.startIndex + i + 4].enumerated()
                .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            return Float(bitPattern: bits)
        }
    }

    /// The best matches for a query vector. Vectors are normalised by the
    /// embedder, so the dot product is the cosine. Captures of the same
    /// window within `mergeWithin` of a better one are left out, so ten
    /// results aren't ten minutes of the same page.
    public static func rank(_ query: [Float], _ shots: [Shot], limit: Int, mergeWithin: TimeInterval = 300) -> [Hit] {
        let scored = shots.compactMap { shot -> Hit? in
            guard shot.vector.count == query.count, !query.isEmpty else { return nil }
            var dot: Float = 0
            for i in 0..<query.count { dot += query[i] * shot.vector[i] }
            return Hit(shot: shot, score: dot)
        }.sorted { $0.score > $1.score }
        var out: [Hit] = []
        for hit in scored where out.count < limit {
            let near = out.contains { kept in
                kept.shot.bundleID == hit.shot.bundleID && kept.shot.title == hit.shot.title
                    && abs(kept.shot.at.timeIntervalSince(hit.shot.at)) < mergeWithin
            }
            if !near { out.append(hit) }
        }
        return out
    }

    /// `remembear search <words> [--limit N] [--days N] [--json]`.
    public struct Query: Equatable, Sendable {
        public var text: String
        public var limit = 10
        public var days: Int?
        public var json = false

        public static func parse(_ args: [String]) -> Query? {
            var words: [String] = []
            var q = Query(text: "")
            var i = 0
            while i < args.count {
                switch args[i] {
                case "--limit":
                    guard i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else { return nil }
                    q.limit = n
                    i += 1
                case "--days":
                    guard i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else { return nil }
                    q.days = n
                    i += 1
                case "--json": q.json = true
                default: words.append(args[i])
                }
                i += 1
            }
            q.text = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return q.text.isEmpty ? nil : q
        }
    }
}
