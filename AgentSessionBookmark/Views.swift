import SwiftUI
import AppKit

// MARK: - Window level modes

enum LevelMode: String, CaseIterable {
    case desktop, floating, normal

    var label: String {
        switch self {
        case .desktop:  return "Sit on the desktop"
        case .floating: return "Float above windows"
        case .normal:   return "Normal window"
        }
    }
}

/// Bridges menu actions from SwiftUI to the AppKit window controller.
@MainActor
final class WindowSettings: ObservableObject {
    @Published var mode: LevelMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "levelMode")
            onModeChange?(mode)
        }
    }
    var onModeChange: ((LevelMode) -> Void)?

    init() {
        let saved = UserDefaults.standard.string(forKey: "levelMode") ?? ""
        mode = LevelMode(rawValue: saved) ?? .desktop
    }
}

// MARK: - Root

struct RootView: View {
    @ObservedObject var model: FeedModel
    @ObservedObject var settings: WindowSettings
    @State private var expanded: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if model.sessions.isEmpty {
                emptyState
            } else {
                list
            }
            footer
        }
        .background(VisualEffect())
        .contextMenu { menu }
    }

    private var liveCount: Int { model.sessions.filter(\.isLive).count }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Agent Session Bookmark")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if liveCount > 0 {
                Text("\(liveCount) live")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
            }
            Menu {
                menu
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    private var list: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 0) {
                let flagged = model.sessions.filter(\.isFlagged)
                if !flagged.isEmpty {
                    sectionLabel("Return to", count: flagged.count, tint: Palette.bookmark)
                }
                ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                    if !flagged.isEmpty && index == flagged.count {
                        sectionLabel("Recent", count: nil, tint: .secondary)
                    }
                    SessionRow(session: session,
                               now: model.now,
                               isExpanded: expanded == session.id,
                               toggle: {
                                   withAnimation(.easeInOut(duration: 0.18)) {
                                       expanded = expanded == session.id ? nil : session.id
                                   }
                               },
                               setFlag: { on in model.setFlag(session, on: on) })
                    .id(session.id)
                    if index < model.sessions.count - 1 && index != flagged.count - 1 {
                        Divider().opacity(0.25).padding(.leading, 30)
                    }
                }
            }
        }
        .onAppear {
            // Dev aid for snapshots: SW_EXPAND=<index> opens that row when the
            // list first appears (the list view only exists once data is loaded).
            let sessions = model.sessions
            guard expanded == nil,
                  let raw = ProcessInfo.processInfo.environment["SW_EXPAND"],
                  let index = Int(raw), sessions.indices.contains(index) else { return }
            expanded = sessions[index].id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                proxy.scrollTo(sessions[index].id, anchor: .top)
            }
        }
        }
        .overlay(alignment: .bottom) {
            // Fade hints that the list continues below the fold.
            LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 22)
                .allowsHitTesting(false)
        }
    }

    private func sectionLabel(_ text: String, count: Int?, tint: Color) -> some View {
        HStack(spacing: 6) {
            if count != nil {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.bookmark)
            }
            Text(text.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(count != nil ? .primary : .secondary)
            if let count {
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5.5).padding(.vertical, 1)
                    .background(Palette.bookmark, in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            if let error = model.error {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error).font(.system(size: 11)).multilineTextAlignment(.center)
            } else if model.lastRefresh == nil {
                ProgressView().controlSize(.small)
            } else {
                Text("No sessions in the last 7 days").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if !model.sessions.isEmpty {
                Text("\(model.sessions.count) sessions · last 7 days")
            }
            Spacer()
            if let error = model.error, !model.sessions.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }
            if let t = model.lastRefresh {
                Text("updated \(t, style: .time)")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder private var menu: some View {
        Picker("Window", selection: $settings.mode) {
            ForEach(LevelMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.inline)
        Divider()
        Button("Refresh now") { model.refresh() }
        Button("Reveal bookmarks folder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Bundle.main.supportDir)
        }
        Divider()
        Button("Quit Agent Session Bookmark") { NSApp.terminate(nil) }
    }
}

// MARK: - Row

struct SessionRow: View {
    let session: Session
    let now: Date
    let isExpanded: Bool
    let toggle: () -> Void
    let setFlag: (Bool) -> Void

    @State private var copied = false
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(live: session.live)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(isExpanded ? 3 : 1)
                        .truncationMode(.tail)
                    HStack(spacing: 5) {
                        if session.isCodex {
                            Text("CODEX")
                                .font(.system(size: 8.5, weight: .bold))
                                .tracking(0.4)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Color(red: 0.0, green: 0.42, blue: 0.40), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.white)
                        }
                        Text(session.project)
                        Text("·")
                        Text(relative(session.lastDate))
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    if let note = session.flag?.note, !note.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Palette.bookmark)
                            Text(note)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.85))
                                .lineLimit(isExpanded ? 3 : 1)
                        }
                        .padding(.top, 1)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    setFlag(!session.isFlagged)
                } label: {
                    Image(systemName: session.isFlagged ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(session.isFlagged ? Palette.bookmark : Color.secondary.opacity(hover ? 0.7 : 0))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(session.isFlagged ? "Remove from Return to" : "Flag: return to this session")
                .padding(.top, 1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .background(hover && !isExpanded ? Color.primary.opacity(0.05) : .clear)
            .onHover { hover = $0 }
            .animation(.easeInOut(duration: 0.12), value: hover)

            if isExpanded {
                preview
                    .padding(.leading, 30)
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
            }
        }
        .background(isExpanded ? Color.primary.opacity(0.04) : .clear)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(session.turns.suffix(3)) { turn in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(turn.role == "user" ? "You" : session.agentLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(turn.role == "user" ? .blue : .purple)
                        if let d = Session.parse(turn.ts) {
                            Text(d, style: .time)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(condense(turn.text))
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(turn.role == "user" ? 4 : 7)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if !session.isLive {
                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.resumeCmd, forType: .string)
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            withAnimation { copied = false }
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy resume command",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(copied ? .green : .accentColor)
                    Text(session.id.prefix(8))
                        .font(.system(size: 10)).monospaced()
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.top, 2)
            } else {
                Text(session.live == "busy" ? "Working now" : "Live, waiting for you")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func condense(_ text: String) -> String {
        // Flatten lines and strip the markdown that reads as noise in a preview.
        text.split(whereSeparator: \.isNewline)
            .map { line -> String in
                var l = line.trimmingCharacters(in: .whitespaces)
                while l.hasPrefix("#") || l.hasPrefix(">") { l.removeFirst(); l = l.trimmingCharacters(in: .whitespaces) }
                return l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
    }

    private func relative(_ date: Date) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.dateTimeStyle = .named
        return f.localizedString(for: date, relativeTo: now)
    }
}

struct StatusDot: View {
    let live: String?
    var body: some View {
        ZStack {
            if live != nil {
                Circle().fill(color.opacity(0.25)).frame(width: 12, height: 12)
            }
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(.white.opacity(live == nil ? 0 : 0.5), lineWidth: 0.5))
        }
        .frame(width: 12, height: 12)
        .help(live == "busy" ? "Live, working" : live == "idle" ? "Live, idle" : "Ended")
    }
    private var color: Color {
        switch live {
        case "busy": return .orange
        case "idle": return .green
        default:     return Color.secondary.opacity(0.35)
        }
    }
}

// MARK: - Palette

enum Palette {
    /// Saturated amber that reads on the light and dark translucent backgrounds.
    static let bookmark = Color(red: 0.80, green: 0.36, blue: 0.02)
}

// MARK: - Material background

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
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
