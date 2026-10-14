import AppKit
import ServiceManagement
import os

private let agentLog = Logger(subsystem: "dev.openmouse", category: "agent")

/// The launchd agent that starts OpenMouse at login with no window or Dock
/// icon, so remapping works without the app being open. It runs this same
/// executable with `--background`; opening OpenMouse from Finder reuses the
/// running process and just shows its window.
@MainActor
enum BackgroundAgent {
    static let plistName = "dev.openmouse.OpenMouse.agent.plist"
    static let backgroundArgument = "--background"
    static let takeoverArgument = "--takeover"

    static var service: SMAppService { .agent(plistName: plistName) }

    /// Launched by launchd rather than by the user.
    static var isAgentProcess: Bool { CommandLine.arguments.contains(backgroundArgument) }

    static var status: SMAppService.Status { service.status }

    /// Turn the agent on the first time OpenMouse runs, replacing the older
    /// "open at login" item so OpenMouse isn't launched twice at login.
    static func enableOnFirstLaunch() {
        let key = "BackgroundAgentEnabledOnce"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        do {
            try service.register()
        } catch {
            agentLog.error("Agent registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            try service.register()
            return
        }
        // Unregistering stops the agent's process. If that's us, start a
        // regular instance first so the open window and remapping carry on.
        if isAgentProcess {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.arguments = [takeoverArgument]
            _ = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
        }
        try await service.unregister()
    }

    /// Only one process may own the devices and the event tap. Returns false
    /// when another instance is already running and this one should exit.
    static func claimSingleInstance() -> Bool {
        let others = {
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .filter { $0 != NSRunningApplication.current && !$0.isTerminated }
        }
        if CommandLine.arguments.contains(takeoverArgument) {
            // The previous instance is being stopped by launchd; wait for it.
            let deadline = Date().addingTimeInterval(5)
            while !others().isEmpty && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        }
        guard let other = others().first else { return true }
        agentLog.info("Another instance (pid \(other.processIdentifier)) is running; exiting")
        if !isAgentProcess { other.activate() }
        return false
    }
}
