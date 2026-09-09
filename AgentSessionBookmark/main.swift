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

/// Borderless, translucent panel hosting the SwiftUI list. Three window modes,
/// chosen by the "window" setting in config.json: sitting on the desktop like a
/// widget, floating above other windows, or behaving as a normal window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: WidgetPanel!
    private var model: FeedModel!
    private var subscriptions = Set<AnyCancellable>()
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = FeedModel(scriptsDir: Bundle.main.scriptsDir)

        logLine("launch")
        panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
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
        let env = ProcessInfo.processInfo.environment
        let devRun = env["SW_SNAPSHOT"] != nil || env["SW_HEIGHT"] != nil
        if !devRun {
            // Dev runs (snapshots, forced heights) must never persist their frame.
            panel.setFrameAutosaveName("AgentSessionBookmarkPanel")
        }

        let host = NSHostingView(rootView: RootView(model: model))
        host.wantsLayer = true
        host.layer?.cornerRadius = 18
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        host.layer?.borderWidth = 0.5
        host.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        panel.contentView = host

        if devRun || !panel.setFrameUsingName("AgentSessionBookmarkPanel") {
            placeInTopRightCorner()
        }
        clampToScreen()
        // Dev aid: SW_HEIGHT=<points> forces a tall panel so snapshots show more rows.
        if let raw = env["SW_HEIGHT"], let h = Double(raw) {
            var f = panel.frame; f.size.height = h; panel.setFrame(f, display: false)
        }

        // The window mode follows config.json; the feed reports the effective value.
        model.$config
            .map(\.window)
            .removeDuplicates()
            .sink { [weak self] mode in self?.apply(mode) }
            .store(in: &subscriptions)

        panel.orderFrontRegardless()
        model.start()

        // Dev aid: SW_TEST_CLOSE=1 simulates Escape, Cmd-W and close() after 2 s
        // and prints whether the panel is still visible, then quits.
        if env["SW_TEST_CLOSE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.panel.cancelOperation(nil)
                self.panel.performClose(nil)
                self.panel.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    print("panel visible after close attempts: \(self.panel.isVisible)")
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

    private func snapshot(to path: String) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Keep the panel no taller than the visible screen and fully on it.
    private func clampToScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame.insetBy(dx: 0, dy: 12)
        var f = panel.frame
        f.size.height = min(f.size.height, vf.height)
        f.size.width = min(f.size.width, vf.width)
        f.origin.y = max(vf.minY, min(f.origin.y, vf.maxY - f.size.height))
        f.origin.x = max(vf.minX, min(f.origin.x, vf.maxX - f.size.width))
        panel.setFrame(f, display: false)
    }

    private func placeInTopRightCorner() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 24, y: vf.maxY - size.height - 24))
    }

    private func apply(_ mode: String) {
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

    /// The panel is the app's only window; if something does close it, bring it
    /// back instead of letting the app fall off the desktop.
    func windowWillClose(_ notification: Notification) {
        guard !terminating else { return }
        logLine("panel closed unexpectedly; reopening")
        DispatchQueue.main.async { [weak self] in self?.panel.orderFrontRegardless() }
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
