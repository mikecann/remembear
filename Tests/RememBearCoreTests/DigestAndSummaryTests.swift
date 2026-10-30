import XCTest
@testable import RememBearCore

final class DigestAndSummaryTests: XCTestCase {
    let t0 = ISO8601DateFormatter().date(from: "2026-10-29T06:20:05Z")!
    let utc = TimeZone(identifier: "UTC")!

    func event(_ kind: RecordedEvent.Kind, _ offset: TimeInterval, text: String? = nil, title: String = "Inbox", target: Target? = nil, keys: String? = nil) -> RecordedEvent {
        RecordedEvent(kind: kind, at: t0.addingTimeInterval(offset), app: "Slack", bundleID: "com.tinyspeck.slackmacgap", windowTitle: title, target: target, keys: keys, text: text)
    }

    func testDigestShowsEachLineOfTextOnce() {
        let events = [
            event(.windowChanged, 0, text: "Channels\n#general\nHello there"),
            event(.snapshot, 30, text: "Channels\n#general\nHello there\nA new message"),
            event(.submit, 40, target: Target(role: "AXTextArea", placeholder: "Message #general", value: "ship it")),
            event(.shortcut, 50, keys: "cmd+k"),
        ]
        let d = Digest.render(events, options: .init(timeZone: utc))
        XCTAssertEqual(d.components(separatedBy: "Hello there").count, 2)
        XCTAssertTrue(d.contains("A new message"))
        XCTAssertTrue(d.contains("06:20:45 pressed Return in textarea \"Message #general\": \"ship it\""))
        XCTAssertTrue(d.contains("shortcut: cmd+k"))
        // Same window, so the place isn't repeated before the submit.
        XCTAssertEqual(d.components(separatedBy: "Slack | Inbox").count, 2)
    }

    func testDigestKeepsToItsBudget() {
        let big = (0..<2_000).map { "line number \($0) with some words" }.joined(separator: "\n")
        let events = (0..<50).map { event(.windowChanged, Double($0), text: big + "\nunique \($0)", title: "Doc \($0)") }
        let d = Digest.render(events, options: .init(budget: 10_000, perSnapshot: 2_000, timeZone: utc))
        XCTAssertLessThan(d.count, 22_000)
        XCTAssertTrue(d.contains("left out"))
        XCTAssertTrue(d.contains("Doc 49"), "event lines survive past the text budget")
    }

    func testApplicationsInFirstSeenOrder() {
        var e1 = event(.click, 0); e1.bundleID = "b"
        var e2 = event(.click, 1); e2.bundleID = "a"
        var e3 = event(.click, 2); e3.bundleID = "b"
        XCTAssertEqual(Digest.applications([e3, e2, e1]), ["b", "a"])
    }

    func testParsesReplyAndRendersAgentArchiveFriendlyFile() throws {
        let reply = """
        ```markdown
        TITLE: Threadbear triage: Paws follow-up
        DESCRIPTION: You reviewed Threadbear threads
        and checked Chrome.
        ## Memory summary

        The user triaged "Paws" work.

        ## Recording summary

        ### Threadbear

        Opened threads.
        ```
        """
        let draft = try SummaryFile.parseReply(reply)
        XCTAssertEqual(draft.title, "Threadbear triage: Paws follow-up")
        XCTAssertEqual(draft.description, "You reviewed Threadbear threads")
        XCTAssertTrue(draft.body.hasPrefix("## Memory summary"))
        XCTAssertTrue(draft.body.hasSuffix("Opened threads."))

        let file = SummaryFile.render(draft, applications: ["com.tinyspeck.slackmacgap", "com.google.Chrome"], citations: ["/tmp/events.jsonl"])
        XCTAssertTrue(file.hasPrefix("---\ntitle: \"Threadbear triage: Paws follow-up\"\ndescription: You reviewed Threadbear threads\napplications: [com.tinyspeck.slackmacgap, com.google.Chrome]\n"))
        XCTAssertTrue(file.contains("\n## Citations\n\n- /tmp/events.jsonl\n"))
        XCTAssertEqual(SummaryFile.title(of: file), "Threadbear triage: Paws follow-up")
        XCTAssertEqual(SummaryFile.body(of: file), draft.body)
    }

    func testRejectsRepliesMissingParts() {
        XCTAssertThrowsError(try SummaryFile.parseReply("DESCRIPTION: x\n## Memory summary\nok")) { XCTAssertEqual($0 as? SummaryFile.ParseError, .missingTitle) }
        XCTAssertThrowsError(try SummaryFile.parseReply("TITLE: x\nDESCRIPTION: y\nno body")) { XCTAssertEqual($0 as? SummaryFile.ParseError, .missingBody) }
    }

    func testYamlQuotingOnlyWhenNeeded() {
        XCTAssertEqual(SummaryFile.yamlScalar("Plain title, with a comma"), "Plain title, with a comma")
        XCTAssertEqual(SummaryFile.yamlScalar("Fix: the \"bug\""), "\"Fix: the 'bug'\"")
        XCTAssertEqual(SummaryFile.yamlScalar("- dash first"), "\"- dash first\"")
    }

    func testPromptsCarryWindowAndPreviousContext() {
        let w = TimeWindow.containing(t0, .tenMinutes)
        let p = Prompts.tenMinute(window: w, digest: "06:20:05 window: Slack | Inbox", previousSummary: "## Memory summary\nEarlier", timeZone: TimeZone(identifier: "Australia/Perth")!)
        XCTAssertTrue(p.hasPrefix("Window: 2026-10-29 06:20 to 06:30 UTC (Thu 29 Oct, 14:20 to 14:30 Australia/Perth)"))
        XCTAssertTrue(p.contains("Earlier"))
        let six = Prompts.sixHour(window: TimeWindow.containing(t0, .sixHours), children: [(w, "child body")], previousRollup: nil, timeZone: utc)
        XCTAssertTrue(six.contains("child body"))
        XCTAssertTrue(six.contains("None."))
    }

    func testEventsRoundTripAndSkipTornLines() throws {
        let e = event(.submit, 0, target: Target(role: "AXTextArea", value: "hi"))
        var data = try EventCoding.encoder().encode(e)
        data.append(contentsOf: Array("\n{\"kind\":\"mouse.cl".utf8))
        XCTAssertEqual(EventCoding.decodeLines(data), [e])
    }
}
