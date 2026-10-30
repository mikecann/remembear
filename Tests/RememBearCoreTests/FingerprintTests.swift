import XCTest
@testable import RememBearCore

final class FingerprintTests: XCTestCase {
    let blank = [UInt8](repeating: 240, count: Fingerprint.side * Fingerprint.side)

    func testTheSameWindowIsTheSame() {
        XCTAssertTrue(Fingerprint.isSame(blank, blank))
        // Compression noise: every pixel a little off.
        XCTAssertTrue(Fingerprint.isSame(blank, blank.map { $0 - 5 }))
        // A caret or spinner: a handful of pixels.
        var caret = blank
        for i in 0..<20 { caret[i * 128 + 60] = 0 }
        XCTAssertTrue(Fingerprint.isSame(blank, caret))
    }

    func testNewContentIsAChange() {
        // A new line of text: a 2-pixel-high band of dark pixels across most of the width.
        var line = blank
        for row in 100..<102 { for col in 10..<118 { line[row * 128 + col] = 40 } }
        XCTAssertFalse(Fingerprint.isSame(blank, line))
        // No earlier fingerprint, or a different size: read it.
        XCTAssertFalse(Fingerprint.isSame(nil, blank))
        XCTAssertEqual(Fingerprint.changedFraction([1, 2], [1, 2, 3]), 1)
    }
}
