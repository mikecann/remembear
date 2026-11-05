import Foundation
import RememBearCore

/// Appends events to `events/<window>.jsonl`, one file per 10-minute window.
final class EventStore {
    private let queue = DispatchQueue(label: "remembear.store")
    private let encoder = EventCoding.encoder()
    private var handle: FileHandle?
    private var handleWindow: TimeWindow?

    /// `written` runs on the main thread with whether the line reached the
    /// file, so the health check only counts what really landed.
    func append(_ event: RecordedEvent, written: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            let ok = write(event)
            if let written { DispatchQueue.main.async { written(ok) } }
        }
    }

    private func write(_ event: RecordedEvent) -> Bool {
        do {
            let window = TimeWindow.containing(event.at, .tenMinutes)
            guard var line = try? encoder.encode(event) else { return false }
            line.append(UInt8(ascii: "\n"))
            if handleWindow != window {
                try? handle?.close()
                handle = nil
                let url = Self.url(window)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
                handleWindow = window
            }
            guard let handle else { handleWindow = nil; return false }
            try handle.write(contentsOf: line)
            return true
        } catch {
            // Opened again next time, in case the file went away.
            try? handle?.close()
            handle = nil
            handleWindow = nil
            return false
        }
    }

    static func url(_ window: TimeWindow) -> URL {
        Paths.events.appendingPathComponent(window.segmentID + ".jsonl")
    }

    /// Windows with a non-empty event file.
    func segments() -> Set<TimeWindow> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.events.path)) ?? []
        return Set(names.compactMap { name -> TimeWindow? in
            guard name.hasSuffix(".jsonl"), let w = TimeWindow.parseSegmentID(String(name.dropLast(6))) else { return nil }
            let size = (try? FileManager.default.attributesOfItem(atPath: Paths.events.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            return size > 0 ? w : nil
        })
    }

    func read(_ window: TimeWindow) -> [RecordedEvent] {
        queue.sync {}  // let queued writes land first
        guard let data = try? Data(contentsOf: Self.url(window)) else { return [] }
        return EventCoding.decodeLines(data)
    }

    func delete(_ window: TimeWindow) {
        queue.sync {
            if handleWindow == window { try? handle?.close(); handle = nil; handleWindow = nil }
            try? FileManager.default.removeItem(at: Self.url(window))
        }
    }

    /// Deletes every raw event, for "clear the last hour" style resets.
    func deleteAll(since: Date) {
        for w in segments() where w.end > since { delete(w) }
    }
}
