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

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !store.config.general.showMenuBarIcon
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

        // One-way: AppKit writes the status item's visibility back through this
        // binding whenever the scene updates, and storing that write would
        // invalidate this body again and spin the main thread forever. The
        // Settings toggle is the only thing that changes the preference.
        MenuBarExtra(isInserted: Binding(
            get: { delegate.store.config.general.showMenuBarIcon },
            set: { _ in }
        )) {
            MenuBarContent()
                .environment(delegate.store)
                .environment(delegate.engine)
        } label: {
            MenuBarLabel(store: delegate.store)
        }
    }
}

/// Its own view so pausing only redraws the icon, not every scene.
private struct MenuBarLabel: View {
    let store: ConfigStore

    var body: some View {
        Image(systemName: store.config.general.paused ? "computermouse" : "computermouse.fill")
    }
}
