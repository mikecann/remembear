import XCTest
@testable import RememBearCore

final class ScreenSearchTests: XCTestCase {
    func shot(_ app: String, _ title: String, _ minutes: Double, _ v: [Float]) -> ScreenSearch.Shot {
        ScreenSearch.Shot(at: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60), app: app, bundleID: "id." + app,
                          title: title, url: nil, excerpt: nil, vector: v)
    }

    func testVectorsSurviveTheDatabase() {
        let v: [Float] = [0.5, -1.25, 3.0e-7, .pi]
        XCTAssertEqual(ScreenSearch.decode(ScreenSearch.encode(v)), v)
        XCTAssertEqual(ScreenSearch.encode(v).count, 16)
        XCTAssertEqual(ScreenSearch.decode(Data([1, 2, 3])), [])
    }

    func testRanksByCosineAndFoldsTheSamePageTogether() {
        let shots = [
            shot("Chrome", "PR #59871", 0, [1, 0]),
            shot("Chrome", "PR #59871", 1, [0.99, 0.14]),   // a minute later, same page
            shot("Slack", "#devx", 2, [0.9, 0.43]),
            shot("Chrome", "PR #59871", 30, [0.95, 0.31]),  // half an hour later: a separate visit
            shot("Finder", "Downloads", 3, [0, 1]),
        ]
        let hits = ScreenSearch.rank([1, 0], shots, limit: 3)
        XCTAssertEqual(hits.map(\.shot.app), ["Chrome", "Chrome", "Slack"])
        XCTAssertEqual(hits.map { Int($0.shot.at.timeIntervalSince1970 - 1_800_000_000) / 60 }, [0, 30, 2])
        // Vectors from another model size are skipped, not crashed on.
        XCTAssertTrue(ScreenSearch.rank([1, 0, 0], shots, limit: 3).isEmpty)
    }

    func testExcerptIsOneShortLine() {
        XCTAssertEqual(ScreenSearch.excerpt(of: "Projects\n\n  69 projects \nNew project"), "Projects · 69 projects · New project")
        XCTAssertNil(ScreenSearch.excerpt(of: " \n "))
        XCTAssertEqual(ScreenSearch.excerpt(of: String(repeating: "a", count: 1000))?.count, ScreenSearch.excerptLength)
    }

    func testParsesTheSearchCommand() {
        XCTAssertEqual(ScreenSearch.Query.parse(["convex", "usage", "chart", "--limit", "5", "--days", "7", "--json"]),
                       ScreenSearch.Query(text: "convex usage chart", limit: 5, days: 7, json: true))
        XCTAssertEqual(ScreenSearch.Query.parse(["that", "pool", "render"])?.limit, 10)
        XCTAssertNil(ScreenSearch.Query.parse([]))
        XCTAssertNil(ScreenSearch.Query.parse(["x", "--limit", "zero"]))
    }
}
