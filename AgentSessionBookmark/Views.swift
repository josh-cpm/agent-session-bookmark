import SwiftUI
import AppKit

// MARK: - Root

struct RootView: View {
    @ObservedObject var model: FeedModel
    @State private var expanded: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.sessions.isEmpty {
                emptyState
            } else {
                list
            }
            footer
        }
        .background(Backdrop())
        .contextMenu { menu }
    }

    private var liveCount: Int { model.sessions.filter(\.isLive).count }
    private var flagged: [Session] { model.sessions.filter(\.isFlagged) }
    private var rangeLabel: String { model.config.days == 1 ? "day" : "\(model.config.days) days" }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    LinearGradient(colors: [Palette.bookmark.opacity(0.95), Palette.bookmarkDeep],
                                   startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: Palette.bookmarkDeep.opacity(0.35), radius: 3, y: 1)
            Text("Agent Session Bookmark")
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.1)
            Spacer(minLength: 6)
            if liveCount > 0 {
                HStack(spacing: 5) {
                    Circle().fill(Palette.live).frame(width: 6, height: 6)
                        .shadow(color: Palette.live.opacity(0.8), radius: 2)
                    Text("\(liveCount) live")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.live)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Palette.live.opacity(0.12), in: Capsule())
            }
            Menu {
                menu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 11)
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 0) {
                if !flagged.isEmpty {
                    sectionLabel("Return to", count: flagged.count, accent: true)
                }
                ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                    if !flagged.isEmpty && index == flagged.count {
                        sectionLabel("Recent", count: nil, accent: false)
                            .padding(.top, 6)
                    }
                    SessionRow(session: session,
                               now: model.now,
                               showAgentTag: model.showAgentTags,
                               previewTurns: model.config.previewTurns,
                               isExpanded: expanded == session.id,
                               toggle: {
                                   withAnimation(.easeInOut(duration: 0.18)) {
                                       expanded = expanded == session.id ? nil : session.id
                                   }
                               },
                               setFlag: { on in model.setFlag(session, on: on) },
                               copyHandoff: { done in model.copyHandoff(session, completion: done) })
                    .id(session.id)
                    let lastInSection = index == flagged.count - 1 || index == model.sessions.count - 1
                    if !lastInSection {
                        Hairline().padding(.leading, 40).padding(.trailing, 14)
                    }
                }
            }
            .padding(.vertical, 4)
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
            LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.5)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 26)
                .allowsHitTesting(false)
        }
    }

    private func sectionLabel(_ text: String, count: Int?, accent: Bool) -> some View {
        HStack(spacing: 6) {
            if accent {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Palette.bookmark)
            }
            Text(text.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(accent ? AnyShapeStyle(Palette.bookmark) : AnyShapeStyle(.tertiary))
            if let count {
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5.5).padding(.vertical, 1)
                    .background(Palette.bookmark, in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: Empty / footer

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            if let error = model.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else if model.lastRefresh == nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("No sessions in the last \(rangeLabel)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !model.sessions.isEmpty {
                Text("\(model.sessions.count) sessions")
                Text("·").foregroundStyle(.quaternary)
                Text("last \(rangeLabel)")
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
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .top) { Hairline() }
    }

    // MARK: Menu (every choice writes config.json through the CLI)

    private func binding(_ keyPath: KeyPath<AppConfig, String>, key: String) -> Binding<String> {
        Binding(get: { model.config[keyPath: keyPath] }, set: { model.setConfig(key, $0) })
    }

    @ViewBuilder private var menu: some View {
        Picker("Show last", selection: Binding(get: { model.config.days },
                                               set: { model.setConfig("days", String($0)) })) {
            ForEach(AppConfig.dayChoices, id: \.self) { d in
                Text(d == 1 ? "1 day" : "\(d) days").tag(d)
            }
            if !AppConfig.dayChoices.contains(model.config.days) {
                Text("\(model.config.days) days").tag(model.config.days)
            }
        }
        Picker("Window", selection: binding(\.window, key: "window")) {
            ForEach(AppConfig.windowChoices, id: \.0) { Text($0.1).tag($0.0) }
        }
        Picker("Agent tags", selection: binding(\.agentTags, key: "agent_tags")) {
            ForEach(AppConfig.tagChoices, id: \.0) { Text($0.1).tag($0.0) }
        }
        Divider()
        Button("Refresh now") { model.refresh() }
        Button("Reveal settings & bookmarks") {
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
    let showAgentTag: Bool
    let previewTurns: Int
    let isExpanded: Bool
    let toggle: () -> Void
    let setFlag: (Bool) -> Void
    let copyHandoff: (@escaping (Bool) -> Void) -> Void

    @State private var copied = false
    @State private var handoffState: HandoffState = .idle
    @State private var hover = false

    enum HandoffState { case idle, working, copied, failed }

    private var agentColor: Color { session.isCodex ? Palette.codex : Palette.claude }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                StatusDot(live: session.live)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 3.5) {
                    Text(session.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .tracking(-0.1)
                        .lineLimit(isExpanded ? 3 : 1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        if showAgentTag {
                            AgentTag(label: session.agentLabel, color: agentColor)
                        }
                        Text(session.project)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("·").foregroundStyle(.quaternary)
                        Text(relative(session.lastDate))
                            .layoutPriority(1)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    if let note = session.flag?.note, !note.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Palette.bookmark)
                            Text(note)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.8))
                                .lineLimit(isExpanded ? 3 : 1)
                        }
                        .padding(.top, 1)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Button {
                        setFlag(!session.isFlagged)
                    } label: {
                        Image(systemName: session.isFlagged ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(session.isFlagged ? Palette.bookmark : Color.secondary.opacity(hover ? 0.75 : 0))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(session.isFlagged ? "Remove from Return to" : "Flag: return to this session")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.quaternary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                }
                .padding(.top, 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)

            if isExpanded {
                preview
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowFill)
                .padding(.horizontal, 6)
        )
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.12), value: hover)
    }

    private var rowFill: Color {
        if isExpanded { return Color.primary.opacity(0.055) }
        if hover { return Color.primary.opacity(0.04) }
        return .clear
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(session.turns.suffix(max(1, previewTurns))) { turn in
                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 6) {
                        Text(turn.role == "user" ? "You" : session.agentLabel)
                            .font(.system(size: 9.5, weight: .bold))
                            .tracking(0.3)
                            .foregroundStyle(turn.role == "user" ? Palette.you : agentColor)
                        if let d = Session.parse(turn.ts) {
                            Text(d, style: .time)
                                .font(.system(size: 9.5))
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
            HStack(spacing: 10) {
                if session.isLive {
                    Button {
                        guard handoffState != .working else { return }
                        handoffState = .working
                        copyHandoff { ok in
                            withAnimation { handoffState = ok ? .copied : .failed }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                                withAnimation { handoffState = .idle }
                            }
                        }
                    } label: {
                        CapsuleLabel(text: handoffLabel, symbol: handoffSymbol,
                                     colors: handoffState == .copied ? [Palette.live, Palette.live.opacity(0.85)]
                                           : handoffState == .failed ? [Color.red, Color.red.opacity(0.85)]
                                           : [Palette.codex.opacity(0.95), Palette.codex])
                    }
                    .buttonStyle(.plain)
                    .help("Copy a brief another agent can paste to take over this session")
                    HStack(spacing: 5) {
                        Circle().fill(session.live == "busy" ? Palette.busy : Palette.live).frame(width: 6, height: 6)
                        Text(session.live == "busy" ? "Working now" : "Waiting for you")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                } else {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.resumeCmd, forType: .string)
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            withAnimation { copied = false }
                        }
                    } label: {
                        CapsuleLabel(text: copied ? "Copied" : "Copy resume command",
                                     symbol: copied ? "checkmark" : "doc.on.doc",
                                     colors: copied ? [Palette.live, Palette.live.opacity(0.85)]
                                                    : [Palette.bookmark, Palette.bookmarkDeep])
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text(session.id.prefix(8))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
            .padding(.top, 1)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.45))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        )
    }

    private var handoffLabel: String {
        switch handoffState {
        case .idle: return "Hand off"
        case .working: return "Preparing…"
        case .copied: return "Brief copied"
        case .failed: return "Failed"
        }
    }
    private var handoffSymbol: String {
        switch handoffState {
        case .copied: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        default: return "arrowshape.turn.up.right.fill"
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

// MARK: - Pieces

/// Small filled capsule button face used for the row actions.
struct CapsuleLabel: View {
    let text: String
    let symbol: String
    let colors: [Color]
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom), in: Capsule())
            .shadow(color: (colors.last ?? .clear).opacity(0.3), radius: 2, y: 1)
    }
}

struct AgentTag: View {
    let label: String
    let color: Color
    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 8, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct StatusDot: View {
    let live: String?
    var body: some View {
        ZStack {
            if live != nil {
                Circle().fill(color.opacity(0.22)).frame(width: 14, height: 14)
            }
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: live == nil ? .clear : color.opacity(0.7), radius: 2)
        }
        .frame(width: 14, height: 14)
        .help(live == "busy" ? "Live, working" : live == "idle" ? "Live, idle" : "Ended")
    }
    private var color: Color {
        switch live {
        case "busy": return Palette.busy
        case "idle": return Palette.live
        default:     return Color.secondary.opacity(0.3)
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5)
    }
}

// MARK: - Palette

enum Palette {
    /// Warm amber for bookmarks; reads on light and dark translucent backgrounds.
    static let bookmark = Color(red: 0.86, green: 0.42, blue: 0.06)
    static let bookmarkDeep = Color(red: 0.70, green: 0.31, blue: 0.02)
    static let live = Color(red: 0.20, green: 0.68, blue: 0.36)
    static let busy = Color(red: 0.95, green: 0.55, blue: 0.10)
    static let you = Color(red: 0.24, green: 0.48, blue: 0.86)
    /// Agent tags and speaker labels.
    static let codex = Color(red: 0.0, green: 0.46, blue: 0.44)     // teal
    static let claude = Color(red: 0.76, green: 0.38, blue: 0.22)   // terracotta
}

// MARK: - Backdrop: material plus a soft top highlight and hairline edge

struct Backdrop: View {
    var body: some View {
        ZStack {
            VisualEffect()
            LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.0)],
                           startPoint: .top, endPoint: .center)
                .blendMode(.plusLighter)
        }
    }
}

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
