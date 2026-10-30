import Foundation

/// A piece of text found in a screenshot, in the window's coordinates
/// scaled to 0...1 with the origin at the top left.
public struct RecognizedText: Equatable, Sendable {
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(text: String, x: Double, y: Double, width: Double, height: Double) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Turns what text recognition found in a window into lines, top to bottom.
public enum ScreenText {
    /// Pieces whose middles sit within half a line of each other are one
    /// row, left to right, joined by two spaces so a table's columns stay
    /// apart (`Privacy.redactScreenText` reads "NAME  value" as a table row).
    public static func lines(_ pieces: [RecognizedText]) -> [String] {
        let sorted = pieces.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { ($0.y + $0.height / 2) < ($1.y + $1.height / 2) }
        var rows: [[RecognizedText]] = []
        for piece in sorted {
            let middle = piece.y + piece.height / 2
            if let last = rows.last?.last,
               abs((last.y + last.height / 2) - middle) < min(last.height, piece.height) / 2 {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows.map { row in
            row.sorted { $0.x < $1.x }.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "  ")
        }
    }
}
