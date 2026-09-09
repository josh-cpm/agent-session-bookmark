import Foundation
import CoreServices

// MARK: - Feed schema (mirrors sessions_feed.py output)

struct Turn: Codable, Identifiable, Hashable {
    let role: String
    let text: String
    let ts: String?
    var id: String { "\(role)-\(ts ?? "")-\(text.hashValue)" }
}

struct Flag: Codable, Hashable {
    let note: String
    let flaggedAt: String?
    enum CodingKeys: String, CodingKey { case note; case flaggedAt = "flagged_at" }
}

struct Session: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let cwd: String
    let project: String
    let source: String
    let agent: String          // "claude" | "codex"
    let firstTs: String?
    let lastTs: String
    let live: String?          // "busy" | "idle" | nil
    let liveName: String?
    let turns: [Turn]
    let resumeCmd: String
    let flag: Flag?

    enum CodingKeys: String, CodingKey {
        case id, title, cwd, project, source, agent, live, turns, flag
        case firstTs = "first_ts"
        case lastTs = "last_ts"
        case liveName = "live_name"
        case resumeCmd = "resume_cmd"
    }

    var isLive: Bool { live != nil }
    var isFlagged: Bool { flag != nil }
    var isCodex: Bool { agent == "codex" }
    var agentLabel: String { isCodex ? "Codex" : "Claude" }
    var lastDate: Date { Session.parse(lastTs) ?? .distantPast }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFractional.date(from: s) ?? iso.date(from: s)
    }
}

struct Feed: Codable {
    let generated: String
    let sessions: [Session]
}

// MARK: - Model: runs the Python feed, watches ~/.claude for changes

@MainActor
final class FeedModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var lastRefresh: Date? = nil
    @Published var error: String? = nil
    @Published var now: Date = Date()

    private let feedScript: String
    private var flagScript: String {
        (feedScript as NSString).deletingLastPathComponent + "/flag.py"
    }
    private var timer: Timer?
    private var tick: Timer?
    private var pending: DispatchWorkItem?
    private var lastRun: Date = .distantPast
    private var stream: FSEventStreamRef?
    private var running = false

    /// Minimum gap between refreshes triggered by file activity. A busy session
    /// appends to its transcript continuously; we do not need every write.
    private let minInterval: TimeInterval = 8
    private let fallbackInterval: TimeInterval = 60

    init(feedScript: String) {
        self.feedScript = feedScript
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: fallbackInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        startWatching()
    }

    func scheduleRefresh() {
        pending?.cancel()
        let wait = max(1.0, minInterval - Date().timeIntervalSince(lastRun))
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    func refresh() {
        guard !running else { return }
        running = true
        lastRun = Date()
        let script = feedScript
        Task.detached(priority: .utility) {
            let result = FeedModel.runFeed(script: script)
            await MainActor.run {
                self.running = false
                switch result {
                case .success(let feed):
                    self.sessions = feed.sessions
                    self.error = nil
                case .failure(let err):
                    self.error = err.localizedDescription
                }
                self.lastRefresh = Date()
                self.now = Date()
            }
        }
    }

    /// Flag or unflag a session via flag.py, then refresh.
    func setFlag(_ session: Session, on: Bool) {
        let script = flagScript
        let args = on ? ["add", session.id] : ["remove", session.id]
        Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [script] + args
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            await MainActor.run { self.refresh() }
        }
    }

    nonisolated private static func runFeed(script: String) -> Result<Feed, Error> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [script]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return .failure(error)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(FeedError.script(status: proc.terminationStatus, stderr: msg))
        }
        do {
            return .success(try JSONDecoder().decode(Feed.self, from: data))
        } catch {
            return .failure(error)
        }
    }

    // MARK: FSEvents

    private func startWatching() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [home + "/.claude/projects", home + "/.claude/sessions", home + "/.codex/sessions"] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, fsEventsCallback, &context, paths,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               2.0, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}

private func fsEventsCallback(_ stream: ConstFSEventStreamRef,
                              _ info: UnsafeMutableRawPointer?,
                              _ count: Int,
                              _ paths: UnsafeMutableRawPointer,
                              _ flags: UnsafePointer<FSEventStreamEventFlags>,
                              _ ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info else { return }
    let model = Unmanaged<FeedModel>.fromOpaque(info).takeUnretainedValue()
    Task { @MainActor in model.scheduleRefresh() }
}

enum FeedError: LocalizedError {
    case script(status: Int32, stderr: String)
    var errorDescription: String? {
        switch self {
        case .script(let status, let stderr):
            let tail = stderr.split(separator: "\n").last.map(String.init) ?? ""
            return "feed exited \(status)" + (tail.isEmpty ? "" : ": \(tail)")
        }
    }
}
