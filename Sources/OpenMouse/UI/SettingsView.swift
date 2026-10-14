import AppKit
import OpenMouseCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(RemapEngine.self) private var engine
    @State private var agentStatus = BackgroundAgent.status
    @State private var agentError: String?
    @State private var optionsPlusRunning = false
    @State private var confirmReset = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if engine.accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { engine.requestAccessibility() }
                    }
                }
                LabeledContent("Input Monitoring") {
                    if engine.devices.inputMonitoringGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { engine.devices.requestInputMonitoring() }
                    }
                }
                LabeledContent("Button & scroll interception") {
                    Text(engine.tapRunning ? "Running" : "Not running").foregroundStyle(engine.tapRunning ? Color.secondary : Color.orange)
                }
                if !engine.accessibilityGranted {
                    Button("Open Privacy & Security Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }

            if optionsPlusRunning {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Logi Options+ is running").font(.headline)
                            Text("Options+ and OpenMouse both configure the mouse over HID++ and will undo each other's settings. Quit or uninstall Logi Options+ (including its background agent) to use OpenMouse.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }

            Section("General") {
                Toggle(isOn: Binding(get: { agentStatus != .notRegistered && agentStatus != .notFound }, set: setRunInBackground)) {
                    Text("Run in background")
                    Text("Starts at login and keeps remapping with this window closed. Quitting OpenMouse stops remapping until you open it again or log in.")
                    if let agentError { Text(agentError).foregroundStyle(.red) }
                }
                if agentStatus == .requiresApproval {
                    LabeledContent("Background item is turned off in System Settings") {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .foregroundStyle(.orange)
                }
                Toggle(isOn: $store.config.general.onlyLogitechDevices) {
                    Text("Only remap Logitech mice")
                    Text("When off, button and scroll settings also apply to other mice. Trackpads are never affected.")
                }
                Toggle("Pause remapping", isOn: $store.config.general.paused)
            }

            Section {
                LabeledContent("Config file") {
                    Button("Show in Finder") {
                        store.saveNow()
                        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.fileURL])
                    }
                }
                LabeledContent("Reset") {
                    Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                }
            } header: {
                Text("Data")
            } footer: {
                Text("Everything is stored locally in \(ConfigStore.fileURL.path(percentEncoded: false)). No account, no network.")
            }

            Section("Diagnostics") {
                if engine.devices.devices.isEmpty {
                    Text("No Logitech HID++ devices found.").foregroundStyle(.secondary)
                    if !engine.devices.receivers.isEmpty {
                        Text("Receivers: \(engine.devices.receivers.joined(separator: ", "))").font(.caption)
                    }
                }
                ForEach(engine.devices.devices) { device in
                    DisclosureGroup {
                        DeviceDiagnostics(device: device)
                    } label: {
                        HStack {
                            Text(device.name)
                            Spacer()
                            Text(device.connected ? "HID++ \(device.protocolVersion)" : "Disconnected")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Rescan Devices") { engine.devices.rescan() }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Text("A local, account-free replacement for Logitech Options+.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { optionsPlusRunning = await Self.isOptionsPlusRunning() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user may have flipped it in System Settings → Login Items.
            agentStatus = BackgroundAgent.status
        }
        .confirmationDialog("Reset all OpenMouse settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { store.config = Config() }
        } message: {
            Text("All button assignments, app profiles and device settings will be lost.")
        }
    }

    private func setRunInBackground(_ enabled: Bool) {
        Task {
            do {
                try await BackgroundAgent.setEnabled(enabled)
                agentError = nil
            } catch {
                agentError = error.localizedDescription
            }
            agentStatus = BackgroundAgent.status
        }
    }

    static func isOptionsPlusRunning() async -> Bool {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-f", "logioptionsplus_agent|LogiOptionsPlus"]
            process.standardOutput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }
}

private struct DeviceDiagnostics: View {
    let device: LogiDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Connection", device.connectionLabel)
            row("Device index", String(format: "0x%02X", device.index))
            row("Type", "\(device.kind)")
            if let dpi = device.dpi { row("DPI", "\(dpi) (\(device.dpiOptions.first ?? 0)–\(device.dpiOptions.last ?? 0))") }
            if let s = device.smartShift { row("Wheel", "\(s.mode == .ratchet ? "ratchet" : "free-spin"), threshold \(s.autoDisengage)") }
            if let t = device.thumbwheel { row("Thumb wheel", "res \(t.nativeResolution)/\(t.divertedResolution), \(device.thumbwheelDiverted ? "diverted" : "native")") }
            if let error = device.lastError { row("Last error", error).foregroundStyle(.red) }
            Text("Reprogrammable controls").font(.caption.weight(.semibold)).padding(.top, 4)
            ForEach(device.diversionSummary, id: \.cid) { entry in
                let info = device.controls.first { $0.cid == entry.cid }
                Text(String(format: "0x%04X", entry.cid)
                     + "  " + (info?.isDivertable == true ? "divertable" : "fixed")
                     + (info?.supportsRawXY == true ? ", raw XY" : "")
                     + (entry.diverted ? "  → diverted\(entry.rawXY ? " +XY" : "")" : ""))
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value)
        }
        .font(.caption)
    }
}
