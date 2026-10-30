import Foundation

/// A capture shrunk to a small grey picture, to tell whether a window has
/// changed since it was last read. Reading text off a big window is most of
/// RememBear's CPU (about 5% of a core while Mike was working, 30 Oct 2026),
/// and the once-a-minute rereads mostly found the same window.
public enum Fingerprint {
    /// Width and height of the grey picture: small enough to compare in
    /// microseconds, big enough that a new line of chat changes hundreds of
    /// its pixels.
    public static let side = 128
    /// How far a pixel's grey can move before it counts as changed, so
    /// compression noise and subpixel shifts don't.
    public static let pixelThreshold: UInt8 = 12
    /// Under this share of changed pixels the window counts as the same: a
    /// blinking caret or a spinner, not new content.
    public static let sameBelow = 0.002

    /// The share of pixels that differ by more than `pixelThreshold`.
    public static func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for i in 0..<a.count where (a[i] > b[i] ? a[i] - b[i] : b[i] - a[i]) > pixelThreshold { changed += 1 }
        return Double(changed) / Double(a.count)
    }

    public static func isSame(_ a: [UInt8]?, _ b: [UInt8]) -> Bool {
        guard let a else { return false }
        return changedFraction(a, b) < sameBelow
    }
}
