import AppKit
import ImageIO
import RememBearCore
import SQLite3
import UniformTypeIdentifiers

/// Talks to RememBear's embedder (embedder/server.py, EmbeddingGemma 2 on
/// this Mac's GPU), starting it when there's something to embed. It quits by
/// itself after ten idle minutes, as the model holds about 3 GB, and starts
/// again in about 7 s.
///
/// Where it's listening and its token are kept in embedder.json (readable
/// only by Mike), so `remembear search` can use the copy the app started
/// rather than load the model a second time.
final class Embedder {
    static let shared = Embedder()

    private struct Connection: Codable {
        var port: Int
        var token: String
        var pid: Int32
    }

    private let lock = NSLock()
    private var connection: Connection?
    private var starting = false
    private var loggedMissing = false

    private static var info: URL { Paths.support.appendingPathComponent("embedder.json") }
    static var python: URL { Paths.support.appendingPathComponent("embedder-venv/bin/python") }

    /// server.py ships inside the app. The command line finds the app through
    /// the symlink in ~/.local/bin.
    static var server: URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let url = exe.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/embedder/server.py")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func embed(image: CGImage) async -> [Float]? {
        guard let jpeg = Self.jpeg(image) else { return nil }
        return await post("/image", body: jpeg)
    }

    func embed(query: String) async -> [Float]? {
        guard let body = try? JSONEncoder().encode(["text": query]) else { return nil }
        return await post("/text", body: body)
    }

    private func post(_ path: String, body: Data, retry: Bool = true) async -> [Float]? {
        guard let c = await connect() else { return nil }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(c.port)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue("Bearer \(c.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let vector = json["vector"] as? [Double] else { return nil }
            return vector.map(Float.init)
        } catch {
            // It quit while idle since we last looked: start it again once.
            forget(c)
            return retry ? await post(path, body: body, retry: false) : nil
        }
    }

    private func forget(_ c: Connection) {
        lock.withLock { if connection?.pid == c.pid { connection = nil } }
        try? FileManager.default.removeItem(at: Self.info)
    }

    /// A running embedder: the one already known, the one embedder.json
    /// names if it's still alive, or a new one.
    private func connect() async -> Connection? {
        if let c = lock.withLock({ () -> Connection? in
            if let c = connection, kill(c.pid, 0) == 0 { return c }
            connection = nil
            return nil
        }) { return c }
        if let data = try? Data(contentsOf: Self.info), let c = try? JSONDecoder().decode(Connection.self, from: data), kill(c.pid, 0) == 0 {
            lock.withLock { connection = c }
            return c
        }
        return await start()
    }

    private func start() async -> Connection? {
        guard FileManager.default.isExecutableFile(atPath: Self.python.path), let server = Self.server else {
            if !loggedMissing {
                loggedMissing = true
                Log.info("screenshot search is off: the embedder isn't installed (run restart.sh)")
            }
            return nil
        }
        // One start at a time: a second caller waits and then connects.
        let alreadyStarting = lock.withLock { () -> Bool in
            if starting { return true }
            starting = true
            return false
        }
        if alreadyStarting { try? await Task.sleep(nanoseconds: 500_000_000); return await connect() }
        defer { lock.withLock { starting = false } }

        let token = UUID().uuidString + UUID().uuidString
        let p = Process()
        p.executableURL = Self.python
        p.arguments = [server.path]
        p.currentDirectoryURL = server.deletingLastPathComponent()
        // Embedding is never urgent, so keep the model off the cores Mike is using.
        p.qualityOfService = .background
        var env = ProcessInfo.processInfo.environment
        env["REMEMBEAR_EMBEDDER_TOKEN"] = token
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            Log.info("couldn't start the embedder: \(error.localizedDescription)")
            return nil
        }
        // "READY <port>" once the model's loaded, which takes a few seconds.
        let port: Int? = await withCheckedContinuation { done in
            DispatchQueue.global().async {
                var buffer = Data()
                while true {
                    let chunk = out.fileHandleForReading.availableData
                    if chunk.isEmpty { done.resume(returning: nil); return }
                    buffer.append(chunk)
                    if let line = String(data: buffer, encoding: .utf8)?.split(separator: "\n").first(where: { $0.hasPrefix("READY ") }) {
                        done.resume(returning: Int(line.dropFirst(6)))
                        return
                    }
                }
            }
        }
        guard let port else {
            Log.info("the embedder didn't start")
            return nil
        }
        let c = Connection(port: port, token: token, pid: p.processIdentifier)
        if let data = try? JSONEncoder().encode(c) {
            FileManager.default.createFile(atPath: Self.info.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        lock.withLock { connection = c }
        Log.info("embedder started (pid \(p.processIdentifier))")
        return c
    }

    /// The screenshot as a JPEG in memory, shrunk to the embedder's 768
    /// pixels so less goes over the loopback. Never written to disk.
    static func jpeg(_ image: CGImage, maxSide: Int = 768) -> Data? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// The searchable captures, in search.sqlite next to the events (readable
/// only by Mike). Vectors and a short masked excerpt; never a picture.
final class ShotStore {
    static let shared = ShotStore()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "remembear.shots")
    static var url: URL { Paths.support.appendingPathComponent("search.sqlite") }

    private init() {
        queue.sync {
            guard sqlite3_open(Self.url.path, &db) == SQLITE_OK else { db = nil; return }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
            sqlite3_exec(db, """
                CREATE TABLE IF NOT EXISTS shots (id INTEGER PRIMARY KEY, at REAL NOT NULL, app TEXT NOT NULL, bundle TEXT NOT NULL,
                  title TEXT, url TEXT, excerpt TEXT, vector BLOB NOT NULL);
                CREATE INDEX IF NOT EXISTS shots_at ON shots(at);
                """, nil, nil, nil)
        }
    }

    func add(_ shot: ScreenSearch.Shot) {
        queue.async { [self] in
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO shots (at, app, bundle, title, url, excerpt, vector) VALUES (?,?,?,?,?,?,?)", -1, &st, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(st) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_double(st, 1, shot.at.timeIntervalSince1970)
            sqlite3_bind_text(st, 2, shot.app, -1, transient)
            sqlite3_bind_text(st, 3, shot.bundleID, -1, transient)
            if let t = shot.title { sqlite3_bind_text(st, 4, t, -1, transient) } else { sqlite3_bind_null(st, 4) }
            if let u = shot.url { sqlite3_bind_text(st, 5, u, -1, transient) } else { sqlite3_bind_null(st, 5) }
            if let e = shot.excerpt { sqlite3_bind_text(st, 6, e, -1, transient) } else { sqlite3_bind_null(st, 6) }
            let blob = ScreenSearch.encode(shot.vector)
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(st, 7, $0.baseAddress, Int32(blob.count), transient) }
            sqlite3_step(st)
        }
    }

    func all(since: Date?) -> [ScreenSearch.Shot] {
        queue.sync {
            var out: [ScreenSearch.Shot] = []
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT at, app, bundle, title, url, excerpt, vector FROM shots WHERE at >= ?", -1, &st, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_double(st, 1, since?.timeIntervalSince1970 ?? 0)
            func text(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
            while sqlite3_step(st) == SQLITE_ROW {
                let n = Int(sqlite3_column_bytes(st, 6))
                let data = sqlite3_column_blob(st, 6).map { Data(bytes: $0, count: n) } ?? Data()
                out.append(ScreenSearch.Shot(at: Date(timeIntervalSince1970: sqlite3_column_double(st, 0)), app: text(1) ?? "", bundleID: text(2) ?? "",
                                             title: text(3), url: text(4), excerpt: text(5), vector: ScreenSearch.decode(data)))
            }
            return out
        }
    }

    /// Drops captures older than `ScreenSearch.keepDays`, and with `since`,
    /// everything from then on (Forget the Last Hour).
    func prune(since: Date? = nil) {
        queue.async { [self] in
            let cutoff = Date().addingTimeInterval(-Double(ScreenSearch.keepDays) * 86_400).timeIntervalSince1970
            sqlite3_exec(db, "DELETE FROM shots WHERE at < \(cutoff)", nil, nil, nil)
            if let since { sqlite3_exec(db, "DELETE FROM shots WHERE at >= \(since.timeIntervalSince1970)", nil, nil, nil) }
        }
    }
}

/// `remembear search <words>`: the captures that looked most like the words,
/// newest-first among equals, for Mike or his agents.
enum SearchCommand {
    static func run(_ args: [String]) -> Int32 {
        guard let q = ScreenSearch.Query.parse(args) else {
            FileHandle.standardError.write(Data("usage: remembear search <words> [--limit N] [--days N] [--json]\n".utf8))
            return 2
        }
        let since = q.days.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        let shots = ShotStore.shared.all(since: since)
        guard !shots.isEmpty else {
            print("Nothing to search yet: RememBear adds each capture as it records.")
            return 0
        }
        var vector: [Float]?
        let done = DispatchSemaphore(value: 0)
        Task { vector = await Embedder.shared.embed(query: q.text); done.signal() }
        done.wait()
        guard let vector else {
            FileHandle.standardError.write(Data("The embedder isn't available. See ~/Library/Logs/remembear.log.\n".utf8))
            return 1
        }
        let hits = ScreenSearch.rank(vector, shots, limit: q.limit)
        let clock = DateFormatter()
        clock.dateFormat = "EEE d MMM HH:mm"
        if q.json {
            let rows: [[String: Any]] = hits.map { h in
                ["at": ISO8601DateFormatter().string(from: h.shot.at), "score": Double(h.score), "app": h.shot.app,
                 "title": h.shot.title ?? NSNull(), "url": h.shot.url ?? NSNull(), "excerpt": h.shot.excerpt ?? NSNull()]
            }
            let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .withoutEscapingSlashes])) ?? Data()
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            for h in hits {
                print("\(clock.string(from: h.shot.at))  \(String(format: "%.2f", h.score))  \(h.shot.app) | \(h.shot.title ?? "untitled")\(h.shot.url.map { " | " + $0 } ?? "")")
                if let e = h.shot.excerpt { print("    \(e.prefix(200))") }
            }
        }
        return 0
    }
}
