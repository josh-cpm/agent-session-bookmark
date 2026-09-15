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

        // A monitor arriving or leaving changes how many panels we need.
        NotificationCenter.default
            .addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                         object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncPanels() }
            }

        syncPanels()
        model.start()

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
    private func syncPanels() {
        let wanted: [(name: String, screen: NSScreen?)] = displays == "all"
            ? NSScreen.screens.map { (panelName(for: $0), $0) }
            : [(singleName, nil)]

        let keep = Set(wanted.map(\.name))
        for (name, panel) in panels where !keep.contains(name) {
            // Drop the delegate first: windowWillClose must not resurrect a
            // panel we are retiring because its monitor went away.
            panel.delegate = nil
            panel.close()
            panels.removeValue(forKey: name)
        }

        for (name, screen) in wanted {
            let panel = panels[name] ?? makePanel(name: name, screen: screen)
            panels[name] = panel
            apply(mode, to: panel)
        }
    }

    private func panelName(for screen: NSScreen) -> String {
        guard let id = screen.displayID else { return singleName }
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

        if !devRun {
            panel.setFrameAutosaveName(name)
        }
        if devRun || !panel.setFrameUsingName(name) {
            // First time this monitor gets a panel: inherit the position the
            // single panel was dragged to if that was on this screen, so
            // turning "all" on does not throw the placement away.
            let inherited = !devRun && name != singleName
                && panel.setFrameUsingName(singleName)
                && (screen?.frame.intersects(panel.frame) ?? false)
            if !inherited {
                placeInTopRightCorner(panel, of: screen ?? NSScreen.main)
            }
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
            panel.collectionBehavior = [.moveToActiveSpace, .managed]
        default:
            // Just above the desktop icons, below every ordinary window: the
            // panel behaves like a macOS desktop widget.
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
        panel.orderFrontRegardless()
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
