import AppKit
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

/// Effective settings, as reported by the feed (defaults overlaid with config.json).
/// Mirrors DEFAULT_CONFIG in asb_paths.py.
struct AppConfig: Codable, Hashable {
    var days: Int = 7
    var maxSessions: Int = 60
    var ignoreCwds: [String] = []
    var window: String = "desktop"       // desktop | floating | normal
    var agentTags: String = "auto"       // auto | always | never
    var previewTurns: Int = 3

    enum CodingKeys: String, CodingKey {
        case days, window
        case maxSessions = "max_sessions"
        case ignoreCwds = "ignore_cwds"
        case agentTags = "agent_tags"
        case previewTurns = "preview_turns"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = try c.decodeIfPresent(Int.self, forKey: .days) ?? 7
        maxSessions = try c.decodeIfPresent(Int.self, forKey: .maxSessions) ?? 60
        ignoreCwds = try c.decodeIfPresent([String].self, forKey: .ignoreCwds) ?? []
        window = try c.decodeIfPresent(String.self, forKey: .window) ?? "desktop"
        agentTags = try c.decodeIfPresent(String.self, forKey: .agentTags) ?? "auto"
        previewTurns = try c.decodeIfPresent(Int.self, forKey: .previewTurns) ?? 3
    }

    static let dayChoices = [1, 3, 7, 14, 30]
    static let windowChoices: [(String, String)] = [
        ("desktop", "Sit on the desktop"), ("floating", "Float above windows"), ("normal", "Normal window"),
    ]
    static let tagChoices: [(String, String)] = [
        ("auto", "When both agents appear"), ("always", "Always"), ("never", "Never"),
    ]
}

struct Feed: Codable {
    let generated: String
    let days: Int?
    let config: AppConfig?
    let sessions: [Session]
}

/// macOS ships no Python of its own. `/usr/bin/python3` is a multi-call stub —
/// the same inode as `/usr/bin/git` and `/usr/bin/clang` — that forwards to the
/// toolchain `xcode-select -p` points at, and refuses to run until that
/// toolchain's licence has been accepted. Installing Xcode is enough to switch
/// the active toolchain and break it, which silently kills the feed. Prefer a
/// real interpreter; keep the stub only as a last resort.
///
/// The toolchain paths below are the real framework binaries the stub forwards
/// to, so they keep working while the licence gate is up. Keep this list in
/// step with `integrations/agent-session-bookmark.sh` and `install.sh`:
/// `test_interpreter_candidates.py` fails if the three drift apart.
let pythonCandidates = [
    "/opt/homebrew/bin/python3",
    "/usr/local/bin/python3",
    "/Library/Developer/CommandLineTools/usr/bin/python3",
    "/Applications/Xcode.app/Contents/Developer/usr/bin/python3",
    "/usr/bin/python3",
]

let pythonExecutable: String = {
    // ASB_PYTHON must be an absolute path, as it is in the shell wrapper: a
    // bare command name would work there and be silently ignored here.
    if let override = ProcessInfo.processInfo.environment["ASB_PYTHON"], !override.isEmpty {
        if !override.hasPrefix("/") {
            logLine("ASB_PYTHON=\(override) ignored: give an absolute path")
        } else if pythonRuns(override) {
            logLine("python: \(override) (ASB_PYTHON)")
            return override
        } else {
            logLine("ASB_PYTHON=\(override) ignored: it did not run")
        }
    }
    if let found = pythonCandidates.first(where: pythonRuns) {
        logLine("python: \(found)")
        return found
    }
    // Nothing ran. Returning the stub makes the next feed run fail with the
    // toolchain's own message, which the panel shows, rather than hiding it.
    logLine("python: no working interpreter; falling back to /usr/bin/python3")
    return "/usr/bin/python3"
}()

/// A candidate counts only if it actually runs: the stub exists and is
/// executable even when it will refuse every invocation.
private func pythonRuns(_ path: String) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: path) else { return false }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = ["-c", ""]
    if case .exited(let status, _, _) = runBounded(proc, timeout: probeTimeout, wantOutput: false) {
        return status == 0
    }
    return false
}

/// How long a candidate gets to prove it runs. The stub can block on an
/// install prompt and a network-mounted interpreter can stall, and either one
/// used to wedge the panel on its loading spinner for good.
private let probeTimeout: TimeInterval = 5
/// How long a script gets. A cold parse of a few hundred transcripts takes
/// well under a second, so this only ever catches something genuinely stuck.
private let scriptTimeout: TimeInterval = 60

enum ProcOutcome {
    case exited(status: Int32, out: Data, err: Data)
    case timedOut
    case failedToStart(Error)
}

/// Runs `proc` to completion, or kills it once `timeout` has passed, and never
/// blocks forever. Nothing here may use `waitUntilExit` or a blocking pipe
/// read: both of those are unbounded, and a single stuck child is enough to
/// stop the panel refreshing for the rest of the process's life.
func runBounded(_ proc: Process, timeout: TimeInterval, wantOutput: Bool) -> ProcOutcome {
    // Never let a child inherit our stdin: one that reads it would block.
    proc.standardInput = FileHandle.nullDevice
    let outPipe = wantOutput ? Pipe() : nil
    let errPipe = wantOutput ? Pipe() : nil
    proc.standardOutput = outPipe ?? FileHandle.nullDevice
    proc.standardError = errPipe ?? FileHandle.nullDevice

    let finished = DispatchSemaphore(value: 0)
    proc.terminationHandler = { _ in finished.signal() }
    do { try proc.run() } catch { return .failedToStart(error) }

    // Drain the pipes on their own queues. A child that fills a pipe buffer
    // blocks until someone reads it, so the reads cannot wait on the exit.
    let box = OutputBox()
    let reads = DispatchGroup()
    if let outPipe {
        DispatchQueue.global().async(group: reads) {
            box.out = outPipe.fileHandleForReading.readDataToEndOfFile()
        }
    }
    if let errPipe {
        DispatchQueue.global().async(group: reads) {
            box.err = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
    }

    if finished.wait(timeout: .now() + timeout) == .timedOut {
        // SIGKILL, not terminate(): a child ignoring SIGTERM is exactly the
        // case this guard exists for, and an orphan would outlive the app.
        kill(proc.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 2)
        _ = reads.wait(timeout: .now() + 2)
        return .timedOut
    }
    _ = reads.wait(timeout: .now() + 2)
    return .exited(status: proc.terminationStatus, out: box.out, err: box.err)
}

/// Holds the drained pipes so the reading queues and the caller touch one
/// object, handed between them by the dispatch group's barrier.
final class OutputBox {
    var out = Data()
    var err = Data()
}

// MARK: - Model: runs the Python feed, watches the agents' stores and config.json

@MainActor
final class FeedModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var lastRefresh: Date? = nil
    @Published var error: String? = nil
    @Published var now: Date = Date()
    @Published var config = AppConfig()

    private let scriptsDir: String
    private var feedScript: String { scriptsDir + "/sessions_feed.py" }
    private var flagScript: String { scriptsDir + "/flag.py" }
    private var configScript: String { scriptsDir + "/asb_config.py" }
    private var handoffScript: String { scriptsDir + "/handoff.py" }
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

    init(scriptsDir: String) {
        self.scriptsDir = scriptsDir
    }

    /// Agent tags on rows: always, never, or only when the list mixes agents.
    var showAgentTags: Bool {
        switch config.agentTags {
        case "always": return true
        case "never": return false
        default: return Set(sessions.map(\.agent)).count > 1
        }
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

    func scheduleRefresh(soon: Bool = false) {
        pending?.cancel()
        let wait = soon ? 0.3 : max(1.0, minInterval - Date().timeIntervalSince(lastRun))
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
            let result = FeedModel.run(script: script, args: [], decode: Feed.self)
            await MainActor.run {
                self.running = false
                switch result {
                case .success(let feed):
                    self.sessions = feed.sessions
                    if let c = feed.config { self.config = c }
                    self.error = nil
                    // Only a refresh that returned data counts as a refresh.
                    // Stamping this on failure too made the footer report the
                    // rows as current while the feed had been dead for hours.
                    self.lastRefresh = Date()
                case .failure(let err):
                    self.error = err.localizedDescription
                }
                self.now = Date()
            }
        }
    }

    /// Flag or unflag a session via flag.py, then refresh.
    func setFlag(_ session: Session, on: Bool) {
        let args = on ? ["add", session.id] : ["remove", session.id]
        runAndRefresh(script: flagScript, args: args)
    }

    /// Change one setting through the same CLI Claude and Codex use, so there is
    /// one writer for config.json. The refresh reads the new effective config back.
    func setConfig(_ key: String, _ value: String) {
        runAndRefresh(script: configScript, args: ["set", key, value])
    }

    /// Build the handoff brief for a session and put it on the clipboard.
    /// Calls back on the main actor with success.
    func copyHandoff(_ session: Session, completion: @escaping (Bool) -> Void) {
        let script = handoffScript
        Task.detached(priority: .userInitiated) {
            let result = FeedModel.runText(script: script, args: [session.id])
            await MainActor.run {
                if case .success(let text) = result, !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    completion(true)
                } else {
                    completion(false)
                }
            }
        }
    }

    nonisolated private static func runText(script: String, args: [String]) -> Result<String, Error> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonExecutable)
        proc.arguments = [script] + args
        switch runBounded(proc, timeout: scriptTimeout, wantOutput: true) {
        case .failedToStart(let error):
            return .failure(error)
        case .timedOut:
            return .failure(FeedError.timedOut(seconds: scriptTimeout))
        case .exited(let status, let out, _):
            guard status == 0 else {
                return .failure(FeedError.script(status: status, stderr: ""))
            }
            return .success(String(data: out, encoding: .utf8) ?? "")
        }
    }

    private func runAndRefresh(script: String, args: [String]) {
        Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pythonExecutable)
            proc.arguments = [script] + args
            _ = runBounded(proc, timeout: scriptTimeout, wantOutput: false)
            await MainActor.run { self.refresh() }
        }
    }

    nonisolated private static func run<T: Decodable>(script: String, args: [String], decode: T.Type) -> Result<T, Error> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonExecutable)
        proc.arguments = [script] + args
        switch runBounded(proc, timeout: scriptTimeout, wantOutput: true) {
        case .failedToStart(let error):
            return .failure(error)
        case .timedOut:
            return .failure(FeedError.timedOut(seconds: scriptTimeout))
        case .exited(let status, let out, let err):
            guard status == 0 else {
                let msg = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .failure(FeedError.script(status: status, stderr: msg))
            }
            do {
                return .success(try JSONDecoder().decode(T.self, from: out))
            } catch {
                return .failure(error)
            }
        }
    }

    // MARK: FSEvents

    private func startWatching() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let support = Bundle.main.supportDir
        try? FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        let paths = [home + "/.claude/projects", home + "/.claude/sessions", home + "/.codex/sessions", support] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        // UseCFTypes makes the callback's `paths` a CFArray of CFString (see fsEventsCallback).
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, fsEventsCallback, &context, paths,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    fileprivate func filesChanged(_ paths: [String]) {
        // Edits to config.json or flags.json (from the CLI, Claude, or Codex)
        // should show up right away; transcript writes can wait for the debounce.
        let support = Bundle.main.supportDir
        scheduleRefresh(soon: paths.contains { $0.hasPrefix(support) })
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
    // With kFSEventStreamCreateFlagUseCFTypes the paths pointer is a CFArray of CFString.
    let changed = (unsafeBitCast(paths, to: CFArray.self) as? [String]) ?? []
    Task { @MainActor in model.filesChanged(changed) }
}

enum FeedError: LocalizedError {
    case script(status: Int32, stderr: String)
    case timedOut(seconds: TimeInterval)
    var errorDescription: String? {
        switch self {
        case .script(let status, let stderr):
            let tail = stderr.split(separator: "\n").last.map(String.init) ?? ""
            return "feed exited \(status)" + (tail.isEmpty ? "" : ": \(tail)")
        case .timedOut(let seconds):
            return "feed did not answer in \(Int(seconds))s and was stopped"
        }
    }
}

extension Bundle {
    /// The Python scripts ship inside the app bundle (see build.sh).
    var scriptsDir: String { resourcePath ?? bundlePath + "/Contents/Resources" }

    /// Where flags.json and config.json live; ASB_HOME overrides it (tests, self-check).
    var supportDir: String {
        ProcessInfo.processInfo.environment["ASB_HOME"]
            ?? NSHomeDirectory() + "/Library/Application Support/Agent Session Bookmark"
    }
}
