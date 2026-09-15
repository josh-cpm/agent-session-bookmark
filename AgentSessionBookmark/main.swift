import AppKit
import Combine
import SwiftUI

/// A panel that cannot be dismissed by accident. NSPanel closes itself on Escape
/// (cancelOperation) once it is key, e.g. after clicking into selectable preview
/// text; that used to end the app because the panel was its only window.
final class WidgetPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { /* Escape: do nothing */ }
    override func performClose(_ sender: Any?) { /* Cmd-W: do nothing */ }
    override var canBecomeKey: Bool { true }
}

func logLine(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(stamp) \(message)\n".data(using: .utf8)!)
}

extension NSScreen {
    /// Identifies a monitor well enough to remember a panel's position on it.
    var displayID: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Borderless, translucent panels hosting the SwiftUI list. Three window modes,
/// chosen by the "window" setting in config.json: sitting on the desktop like a
/// widget, floating above other windows, or behaving as a normal window. The
/// "displays" setting decides whether there is one panel or one per monitor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Panels by frame-autosave name, which is also how a panel is matched to
    /// the monitor it belongs to across screen changes.
    private var panels: [String: WidgetPanel] = [:]
    private var model: FeedModel!
    private var subscriptions = Set<AnyCancellable>()
    private var terminating = false
    private var devRun = false
    private var mode = "desktop"
    private var displays = "one"
    private var screenObserver: NSObjectProtocol?
    private var syncScheduled = false

    /// The name a single panel has always used. Kept as-is so an existing
    /// installation keeps the position it was dragged to.
    private let singleName = "AgentSessionBookmarkPanel"

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = FeedModel(scriptsDir: Bundle.main.scriptsDir)
        logLine("launch")

        let env = ProcessInfo.processInfo.environment
        // Dev runs (snapshots, forced heights) must never persist their frame.
        devRun = env["SW_SNAPSHOT"] != nil || env["SW_HEIGHT"] != nil

        // Window mode and monitor count both follow config.json; the feed
        // reports the effective values.
        model.$config
            .map { ($0.window, $0.displays) }
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] window, displays in
                self?.mode = window
                self?.displays = displays
                self?.syncPanels()
            }
            .store(in: &subscriptions)

        // A monitor arriving or leaving changes how many panels we need. The
        // token is kept because the API contract asks for it: without it the
        // observation can never be removed. Reconfiguring displays posts this
        // several times in a burst, so the work is coalesced.
        screenObserver = NotificationCenter.default
            .addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                         object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleSync() }
            }

        // No syncPanels() here: subscribing above already emitted the current
        // config and built the panels. Calling it again only re-applied the
        // window mode to the panels that were just made.
        model.start()

        // Dev aid: SW_PANEL_TRACE=1 reports panel lifetime once a second. A
        // panels count below the window count, or more list renders per refresh
        // than there are panels, means a retired panel is still alive.
        if env["SW_PANEL_TRACE"] != nil {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    logLine("trace panels=\(self.panels.count) windows=\(NSApp.windows.count)"
                            + " visible=\(NSApp.windows.filter(\.isVisible).count)"
                            + " renders=\(RenderCount.bodies)")
                }
            }
        }

        // Dev aid: SW_TEST_CLOSE=1 simulates Escape, Cmd-W and close() after 2 s
        // and prints whether the panel is still visible, then quits.
        if env["SW_TEST_CLOSE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let panel = self.panels.values.first else { return }
                panel.cancelOperation(nil)
                panel.performClose(nil)
                panel.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    print("panel visible after close attempts: \(panel.isVisible)")
                    NSApp.terminate(nil)
                }
            }
        }

        // Dev aid: SW_SNAPSHOT=/path.png renders the panel to a PNG after a few
        // seconds and quits. Needs no screen-recording permission.
        if let path = env["SW_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.snapshot(to: path)
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Panels

    /// In "all" mode every screen gets its own panel, so moving to another
    /// monitor still shows the list on that monitor's desktop. In "one" mode a
    /// single panel lives wherever it was last dragged, as it always has.
    ///
    /// Collapses a burst of screen-parameter changes into one sync. Waking from
    /// sleep or changing a resolution posts the notification repeatedly, and
    /// each sync re-asserts window levels and ordering.
    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.syncPanels()
        }
    }

    private func syncPanels() {
        let wanted: [(name: String, screen: NSScreen?)] = displays == "all"
            ? NSScreen.screens.enumerated().map { (panelName(for: $1, index: $0), $1) }
            : [(singleName, nil)]

        // Iterating `panels` while removing from it is safe: the loop holds its
        // own copy-on-write snapshot, so every original entry is still visited.
        let keep = Set(wanted.map(\.name))
        for (name, panel) in panels where !keep.contains(name) {
            retire(panel)
            panels.removeValue(forKey: name)
        }

        for (name, screen) in wanted {
            let panel = panels[name] ?? makePanel(name: name, screen: screen)
            panels[name] = panel
            // A monitor that went away can leave a panel at coordinates on no
            // screen at all, where it is invisible and cannot be dragged back.
            // Re-clamping on every sync is a no-op for a panel already in view.
            clampToScreen(panel, to: screen)
            apply(mode, to: panel)
        }
    }

    /// Lets go of everything that keeps a panel working, in an order that
    /// matters. Dropping our reference is not enough: a panel whose monitor was
    /// unplugged used to keep its hosting view, which stayed subscribed to the
    /// feed and laid the whole list out again on every refresh, for the rest of
    /// the process's life. Measured with SW_PANEL_TRACE: renders per refresh
    /// now match the number of panels on screen, not the number ever created.
    ///
    /// AppKit still keeps the closed NSWindow itself, because a window that is
    /// not released when closed stays in the application's window list, and
    /// releasing it there instead is an over-release under ARC. What is left is
    /// an inert shell with no content, no delegate and no subscriptions, and
    /// there is at most one per display configuration seen in a session. The
    /// trace reports `windows` above `panels` for exactly that reason.
    private func retire(_ panel: WidgetPanel) {
        // The delegate goes first, so windowWillClose cannot revive a panel we
        // are deliberately retiring.
        panel.delegate = nil
        // The hosting view is the expensive part: it is what observes the feed.
        panel.contentView = nil
        // Give up the autosave name so a panel for this monitor later can claim
        // it. The frame already written to defaults stays there, so the
        // position is still remembered when the monitor comes back.
        panel.setFrameAutosaveName("")
        panel.close()
    }

    /// Every screen needs its own key. Falling back to the single panel's name
    /// would overwrite the one-panel position and collide with a second screen
    /// in the same state, leaving that screen with no panel at all.
    private func panelName(for screen: NSScreen, index: Int) -> String {
        guard let id = screen.displayID else { return "\(singleName)-screen\(index)" }
        return "\(singleName)-\(id)"
    }

    private func makePanel(name: String, screen: NSScreen?) -> WidgetPanel {
        let panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
                                styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = false
        panel.minSize = NSSize(width: 300, height: 220)

        let host = NSHostingView(rootView: RootView(model: model))
        host.wantsLayer = true
        host.layer?.cornerRadius = 18
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        host.layer?.borderWidth = 0.5
        host.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        panel.contentView = host

        // Where the panel goes. Reading a saved frame changes the panel, so each
        // read is its own statement here: the old single expression hid three
        // side effects behind `&&` and relied on short-circuit order to keep
        // dev runs from touching saved frames at all.
        //
        // A monitor with its own remembered frame wins. Otherwise a new
        // monitor's panel starts from the single panel's frame: its size
        // always, so every monitor shows the panel at the size you use, and its
        // position only if the frame lands on this monitor, so switching to
        // "all" does not discard a placement you chose.
        //
        // Note that AppKit constrains a restored frame to the active screen
        // before handing it back, so the test below is against where the frame
        // actually landed, not against what was saved. In practice one monitor
        // keeps the old position and the others get their own corner.
        var positioned = false
        if !devRun {
            panel.setFrameAutosaveName(name)
            positioned = panel.setFrameUsingName(name)
            if !positioned && name != singleName {
                let adopted = panel.setFrameUsingName(singleName)
                positioned = adopted && screen?.frame.intersects(panel.frame) == true
            }
        }
        if !positioned {
            placeInTopRightCorner(panel, of: screen ?? NSScreen.main)
        }
        clampToScreen(panel, to: screen)

        // Dev aid: SW_HEIGHT=<points> forces a tall panel so snapshots show more rows.
        if let raw = ProcessInfo.processInfo.environment["SW_HEIGHT"], let h = Double(raw) {
            var f = panel.frame; f.size.height = h; panel.setFrame(f, display: false)
        }
        return panel
    }

    private func snapshot(to path: String) {
        guard let view = panels.values.first?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Keep a panel no taller than its screen and fully on it.
    private func clampToScreen(_ panel: WidgetPanel, to screen: NSScreen?) {
        guard let screen = screen ?? panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame.insetBy(dx: 0, dy: 12)
        var f = panel.frame
        f.size.height = min(f.size.height, vf.height)
        f.size.width = min(f.size.width, vf.width)
        f.origin.y = max(vf.minY, min(f.origin.y, vf.maxY - f.size.height))
        f.origin.x = max(vf.minX, min(f.origin.x, vf.maxX - f.size.width))
        panel.setFrame(f, display: false)
    }

    private func placeInTopRightCorner(_ panel: WidgetPanel, of screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 24, y: vf.maxY - size.height - 24))
    }

    private func apply(_ mode: String, to panel: WidgetPanel) {
        switch mode {
        case "floating":
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        case "normal":
            panel.level = .normal
            // A single normal window follows you to the Space you are on. A
            // per-display panel must not: it belongs to one monitor, which is
            // the whole point of showing one on each.
            panel.collectionBehavior = displays == "all" ? [.managed] : [.moveToActiveSpace, .managed]
        default:
            // Just above the desktop icons, below every ordinary window: the
            // panel behaves like a macOS desktop widget.
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
        // Re-asserting the order keeps a desktop or floating panel where it
        // belongs after a Space or display change. A normal window should not
        // jump the stack every time a monitor is plugged in, so it is only
        // ordered in when it is not already showing.
        if mode != "normal" || !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// A panel is how the app is seen; if something does close one, bring it
    /// back instead of letting the app fall off the desktop.
    func windowWillClose(_ notification: Notification) {
        guard !terminating, let panel = notification.object as? WidgetPanel else { return }
        logLine("panel closed unexpectedly; reopening")
        DispatchQueue.main.async { panel.orderFrontRegardless() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        logLine("terminating (Quit from the menu, or asked by the system)")
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar takeover
    app.run()
}
