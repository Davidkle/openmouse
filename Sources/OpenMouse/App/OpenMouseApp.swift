import AppKit
import OpenMouseCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: ConfigStore
    let engine: RemapEngine
    private var shuttingDown = false

    override init() {
        store = ConfigStore()
        engine = RemapEngine(store: store)
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard BackgroundAgent.claimSingleInstance() else { exit(0) }
        // LSUIElement starts every launch as an accessory; a launch by the
        // user gets a Dock icon right away.
        if !BackgroundAgent.isAgentProcess { NSApp.setActivationPolicy(.regular) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.start()
        BackgroundAgent.enableOnFirstLaunch()
        observeWindows()
        if BackgroundAgent.isAgentProcess {
            // Started at login: keep remapping, but don't put a window up.
            DispatchQueue.main.async {
                for window in NSApp.windows where Self.isAppWindow(window) { window.close() }
            }
        }
    }

    /// Keeps running with no window: remapping lives in this process.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Show the Dock icon only while the settings window is open.
    private func observeWindows() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, Self.isAppWindow(window) else { return }
                if NSApp.activationPolicy() != .regular {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let closing = note.object as? NSWindow, Self.isAppWindow(closing) else { return }
                let othersOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && Self.isAppWindow($0) }
                if !othersOpen { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    /// A titled document-style window, as opposed to menus and panels.
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel)
    }

    /// Hand every diverted control back to the firmware before quitting so
    /// buttons keep their native behavior without OpenMouse running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shuttingDown else { return .terminateNow }
        shuttingDown = true
        store.saveNow()
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.engine.shutdown() }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct OpenMouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("OpenMouse", id: "main") {
            ContentView()
                .environment(delegate.store)
                .environment(delegate.engine)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1060, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
