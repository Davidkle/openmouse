import OpenMouseCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case buttons = "Buttons"
    case scrolling = "Scrolling"
    case pointer = "Pointer"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .buttons: return "computermouse"
        case .scrolling: return "scroll"
        case .pointer: return "cursorarrow.motionlines"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(RemapEngine.self) private var engine
    @Environment(ConfigStore.self) private var store
    @State private var section: Page? = ProcessInfo.processInfo.environment["OPENMOUSE_PAGE"].flatMap { Page(rawValue: $0.capitalized) } ?? .buttons
    @State private var selectedDeviceID: String?

    private var device: LogiDevice? {
        let list = engine.devices.pointerDevices
        return list.first { $0.id == selectedDeviceID } ?? list.first { $0.connected } ?? list.first
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section {
                    DeviceHeader(device: device, selection: $selectedDeviceID)
                        .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 12, trailing: 4))
                        .selectionDisabled()
                }
                Section("Customize") {
                    ForEach([Page.buttons, .scrolling, .pointer]) { s in
                        Label(s.rawValue, systemImage: s.symbol).tag(s)
                    }
                }
                Section {
                    Label(Page.settings.rawValue, systemImage: Page.settings.symbol).tag(Page.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
            .safeAreaInset(edge: .bottom) {
                StatusFooter().padding(12)
            }
        } detail: {
            VStack(spacing: 0) {
                if !engine.accessibilityGranted {
                    PermissionBanner()
                }
                if let error = store.loadError {
                    Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: error)
                }
                switch section ?? .buttons {
                case .buttons: ButtonsView(device: device)
                case .scrolling: ScrollingView(device: device)
                case .pointer: PointerView(device: device)
                case .settings: SettingsView()
                }
            }
            .navigationTitle(section?.rawValue ?? "OpenMouse")
            .navigationSubtitle(device?.name ?? "No mouse connected")
        }
    }
}

struct DeviceHeader: View {
    let device: LogiDevice?
    @Binding var selection: String?
    @Environment(RemapEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.tint.opacity(0.15))
                    Image(systemName: "computermouse.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    if engine.devices.pointerDevices.count > 1 {
                        Picker("Device", selection: Binding(get: { device?.id }, set: { selection = $0 })) {
                            ForEach(engine.devices.pointerDevices) { d in
                                Text(d.name).tag(Optional(d.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    } else {
                        Text(device?.name ?? "No mouse found")
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let battery = device?.battery {
                BatteryView(battery: battery)
            }
        }
    }

    private var statusLine: String {
        guard let device else { return "Connect a Logitech mouse" }
        if !device.connected { return "Asleep or disconnected" }
        if !device.ready { return "Connecting…" }
        return device.connectionLabel
    }
}

struct BatteryView: View {
    let battery: BatteryStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            if let percent = battery.percent {
                Text("\(percent)%").monospacedDigit()
            }
            if battery.state == .charging {
                Text("Charging").foregroundStyle(.secondary)
            } else if battery.state == .full {
                Text("Charged").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private var symbol: String {
        if battery.state == .charging { return "battery.100percent.bolt" }
        switch battery.percent ?? 50 {
        case 0..<13: return "battery.0percent"
        case 13..<38: return "battery.25percent"
        case 38..<63: return "battery.50percent"
        case 63..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var color: Color {
        (battery.percent ?? 100) < 15 && battery.state != .charging ? .red : .secondary
    }
}

struct StatusFooter: View {
    @Environment(RemapEngine.self) private var engine
    @Environment(ConfigStore.self) private var store
    @Environment(UpdateController.self) private var updates

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 8) {
            UpdateBanner(updates: updates)
            Toggle(isOn: Binding(get: { !store.config.general.paused }, set: { store.config.general.paused = !$0 })) {
                Text("Remapping enabled")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            if let activity = engine.lastActivity {
                Text(activity)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Banner: View {
    let symbol: String
    let tint: Color
    let text: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).lineLimit(2)
            Spacer()
            if let action {
                Button(action.0, action: action.1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12))
    }
}

struct PermissionBanner: View {
    @Environment(RemapEngine.self) private var engine

    var body: some View {
        Banner(
            symbol: "hand.raised.fill",
            tint: .orange,
            text: "OpenMouse needs Accessibility access to remap buttons and scrolling.",
            action: ("Grant Access…", { engine.requestAccessibility() })
        )
    }
}

/// Shown above the footer only when there's something to do: an update is
/// ready, is installing, or needs an administrator.
private struct UpdateBanner: View {
    let updates: UpdateController

    var body: some View {
        switch updates.status {
        case .available:
            Button {
                updates.installAvailableUpdate()
            } label: {
                Label(updates.latestVersion.map { "Update App (\($0))" } ?? "Update App",
                      systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.callout)
            }
        case .requiresAdmin:
            Label("Updating to \(updates.latestVersion ?? "the new version") requires an admin", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}
