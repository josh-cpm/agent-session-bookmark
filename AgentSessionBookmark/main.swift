import AppKit
import SwiftUI

/// Borderless, translucent panel hosting the SwiftUI list. Three window modes
/// (see LevelMode): sitting on the desktop like a widget, floating above other
/// windows, or behaving as a normal window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private let settings = WindowSettings()
    private var model: FeedModel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let feedScript = Bundle.main.scriptsDir + "/sessions_feed.py"
        model = FeedModel(feedScript: feedScript)

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
                        styleMask: [.borderless, .nonactivatingPanel, .resizable],
                        backing: .buffered, defer: false)
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

        let host = NSHostingView(rootView: RootView(model: model, settings: settings))
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        panel.contentView = host

        if devRun || !panel.setFrameUsingName("AgentSessionBookmarkPanel") {
            placeInTopRightCorner()
        }
        clampToScreen()
        // Dev aid: SW_HEIGHT=<points> forces a tall panel so snapshots show more rows.
        if let raw = env["SW_HEIGHT"], let h = Double(raw) {
            var f = panel.frame; f.size.height = h; panel.setFrame(f, display: false)
        }

        settings.onModeChange = { [weak self] mode in self?.apply(mode) }
        apply(settings.mode)

        panel.orderFrontRegardless()
        model.start()

        // Dev aid: SW_SNAPSHOT=/path.png renders the panel to a PNG after a few
        // seconds and quits. Needs no screen-recording permission.
        if let path = ProcessInfo.processInfo.environment["SW_SNAPSHOT"] {
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

    private func apply(_ mode: LevelMode) {
        switch mode {
        case .desktop:
            // Just above the desktop icons, below every ordinary window: the
            // panel behaves like a macOS desktop widget.
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        case .floating:
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        case .normal:
            panel.level = .normal
            panel.collectionBehavior = [.moveToActiveSpace, .managed]
        }
        panel.orderFrontRegardless()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar takeover
    app.run()
}
