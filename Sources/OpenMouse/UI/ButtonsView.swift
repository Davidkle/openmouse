import AppKit
import OpenMouseCore
import SwiftUI

struct ButtonsView: View {
    let device: LogiDevice?
    @Environment(ConfigStore.self) private var store
    @Environment(RemapEngine.self) private var engine
    @State private var selection: Hotspot = .control(.gestureButton)
    @State private var profileID: UUID?

    /// Controls to show: what the connected mouse supports, or an MX Master
    /// layout when no mouse has been found yet.
    private var hotspots: [Hotspot] {
        var spots: [Hotspot] = [.control(.middleClick)]
        if let device, device.ready {
            let divertable = device.divertableButtons
            for b in [ButtonID.wheelTiltLeft, .wheelTiltRight, .modeShift] where divertable.contains(b) {
                spots.append(.control(b))
            }
            if device.hasThumbwheel { spots.append(.thumbwheel) }
            spots += [.control(.forward), .control(.back)]
            for b in [ButtonID.gestureButton, .hapticPanel] where divertable.contains(b) {
                spots.append(.control(b))
            }
        } else {
            spots += [.control(.modeShift), .thumbwheel, .control(.forward), .control(.back), .control(.gestureButton)]
        }
        return spots
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 16) {
                ProfileBar(profileID: $profileID)
                MouseDiagram(hotspots: hotspots, selection: $selection, summary: summary)
                    .padding(.horizontal, 24)
                    .frame(maxHeight: .infinity)
                Text("Click a highlighted control to change what it does.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(minWidth: 300, maxWidth: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selection {
                    case let .control(button):
                        ControlEditor(button: button, profileID: profileID, device: device)
                    case .thumbwheel:
                        ThumbwheelEditor(profileID: profileID, showsHeader: true)
                    }
                    Divider()
                    AllControlsList(hotspots: hotspots, selection: $selection, summary: summary)
                }
                .padding(20)
            }
            .frame(width: 360)
        }
        .onAppear {
            if !hotspots.contains(selection) { selection = hotspots.first ?? .control(.middleClick) }
        }
        .onChange(of: hotspots) { _, spots in
            if !spots.contains(selection) { selection = spots.first ?? .control(.middleClick) }
        }
    }

    private func summary(_ spot: Hotspot) -> String {
        switch spot {
        case let .control(b):
            let binding = store.binding(for: b, profile: profileID)
            return binding == .default ? "Default" : binding.summary
        case .thumbwheel:
            let remapped = [ButtonID.thumbwheelUp, .thumbwheelDown, .thumbwheelTap]
                .contains { store.binding(for: $0, profile: profileID) != .default }
            return remapped ? "Custom" : "Default"
        }
    }
}

/// Picks which profile is being edited: all apps, or one app's overrides.
private struct ProfileBar: View {
    @Binding var profileID: UUID?
    @Environment(ConfigStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "app.badge")
                .foregroundStyle(.secondary)
            Picker("Profile", selection: $profileID) {
                Text("All Applications").tag(UUID?.none)
                if !store.config.appProfiles.isEmpty { Divider() }
                ForEach(store.config.appProfiles) { profile in
                    Label {
                        Text(profile.name)
                    } icon: {
                        AppIcon(path: profile.appPath, bundleID: profile.bundleID)
                    }
                    .tag(Optional(profile.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)

            Menu {
                let running = NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                    .filter { app in !store.config.appProfiles.contains { $0.bundleID == app.bundleIdentifier } }
                    .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
                Section("Running Applications") {
                    ForEach(running, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                            add(bundleID: app.bundleIdentifier!, name: app.localizedName ?? "App", path: app.bundleURL?.path)
                        }
                    }
                }
                Divider()
                Button("Choose Application…", action: choose)
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Add an app-specific profile")

            if let profileID {
                Button {
                    store.config.appProfiles.removeAll { $0.id == profileID }
                    self.profileID = nil
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .help("Remove this app profile")
            }
            Spacer()
        }
    }

    private func add(bundleID: String, name: String, path: String?) {
        let profile = AppProfile(bundleID: bundleID, name: name, appPath: path)
        store.config.appProfiles.append(profile)
        profileID = profile.id
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        if let existing = store.config.appProfiles.first(where: { $0.bundleID == id }) {
            profileID = existing.id
            return
        }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        add(bundleID: id, name: name, path: url.path)
    }
}

struct AppIcon: View {
    let path: String?
    let bundleID: String

    var body: some View {
        let url = path.map { URL(fileURLWithPath: $0) } ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        if let url {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "app")
        }
    }
}

/// Editor for one button: single action or per-direction gestures.
private struct ControlEditor: View {
    let button: ButtonID
    let profileID: UUID?
    let device: LogiDevice?
    @Environment(ConfigStore.self) private var store

    private var binding: ButtonBinding { store.binding(for: button, profile: profileID) }
    private var overridden: Bool { store.isOverridden(button, profile: profileID) }
    private var inherits: Bool { profileID != nil && !overridden }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: button.symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(button.label).font(.title3.weight(.semibold))
                    Text("Default: \(button.nativeBehavior)").font(.caption).foregroundStyle(.secondary)
                }
            }

            if profileID != nil {
                HStack {
                    Image(systemName: inherits ? "link" : "pencil")
                    Text(inherits ? "Using the All Applications setting" : "Overridden for this app")
                    Spacer()
                    if overridden {
                        Button("Use All Applications") { store.setBinding(nil, for: button, profile: profileID) }
                            .controlSize(.small)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if button.supportsGestures {
                Picker("Mode", selection: Binding(
                    get: { binding.isGesture },
                    set: { gestures in
                        if gestures {
                            let click: Action = { if case let .single(a) = binding, a != .systemDefault { return a }; return button.nativeAction }()
                            var g = button == .gestureButton ? GestureActions.desktopNavigation : GestureActions()
                            if button != .gestureButton { g.click = click }
                            set(.gestures(g))
                        } else {
                            if case let .gestures(g) = binding { set(.single(g.click)) }
                        }
                    }
                )) {
                    Text("Single Action").tag(false)
                    Text("Gestures").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch binding {
            case let .single(action):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Action").font(.subheadline.weight(.medium))
                    ActionPicker(action: Binding(get: { action }, set: { set(.single($0)) }),
                                 defaultLabel: "Default (\(button.nativeBehavior))")
                }
            case let .gestures(actions):
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hold the button and move the mouse").font(.subheadline.weight(.medium))
                    if let warning = gestureWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(GestureDirection.allCases, id: \.self) { direction in
                        HStack {
                            // The header already says "hold", so rows stay short
                            // and the pickers get the room.
                            Label(direction == .click ? "Click" : "Move \(direction.rawValue)", systemImage: direction.symbol)
                                .frame(width: 110, alignment: .leading)
                            ActionPicker(
                                action: Binding(get: { actions[direction] }, set: { new in
                                    var g = actions
                                    g[direction] = new
                                    set(.gestures(g))
                                }),
                                allowDefault: false
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            if !button.isEventTapButton, let device, device.ready, !device.divertableButtons.contains(button) {
                Label("\(device.name) doesn't report this control as remappable.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gestureWarning: String? {
        guard !button.isEventTapButton, let device, device.ready else { return nil }
        return device.supportsGestureRawXY(button) ? nil : "This mouse can't report movement for this control, so only Click will work."
    }

    private func set(_ new: ButtonBinding) {
        store.setBinding(new, for: button, profile: profileID)
    }
}

/// Thumb wheel bindings (shared with the Scrolling page).
struct ThumbwheelEditor: View {
    let profileID: UUID?
    var showsHeader = false
    @Environment(ConfigStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader { HStack(spacing: 12) {
                Image(systemName: "dial.medium")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.tint.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Thumb Wheel").font(.title3.weight(.semibold))
                    Text("Default: horizontal scrolling").font(.caption).foregroundStyle(.secondary)
                }
            } }
            ForEach([ButtonID.thumbwheelUp, .thumbwheelDown, .thumbwheelTap], id: \.self) { b in
                HStack {
                    Label(b.label.replacingOccurrences(of: "Thumb Wheel ", with: ""), systemImage: b.symbol)
                        .frame(width: 90, alignment: .leading)
                    ActionPicker(
                        action: Binding(
                            get: { if case let .single(a) = store.binding(for: b, profile: profileID) { return a }; return .systemDefault },
                            set: { store.setBinding($0 == .systemDefault && profileID == nil ? nil : .single($0), for: b, profile: profileID) }
                        ),
                        defaultLabel: "Default (\(b.nativeBehavior))"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if profileID == nil {
                Toggle("Reverse direction", isOn: $store.config.scroll.invertThumbwheel)
                LabeledContent("Speed") {
                    SpeedSlider(value: $store.config.scroll.thumbwheelSpeed)
                }
            }
        }
    }
}

private struct AllControlsList: View {
    let hotspots: [Hotspot]
    @Binding var selection: Hotspot
    let summary: (Hotspot) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("All Controls").font(.subheadline.weight(.medium)).padding(.bottom, 4)
            ForEach(hotspots) { spot in
                Button {
                    withAnimation(.snappy) { selection = spot }
                } label: {
                    HStack {
                        Image(systemName: spot.symbol).frame(width: 20)
                        Text(spot.label)
                        Spacer()
                        Text(summary(spot))
                            .foregroundStyle(summary(spot) == "Default" ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(spot == selection ? Color.accentColor.opacity(0.15) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SpeedSlider: View {
    @Binding var value: Double

    var body: some View {
        HStack {
            Image(systemName: "tortoise").foregroundStyle(.secondary)
            Slider(value: $value, in: 0.25...4, step: 0.25)
            Image(systemName: "hare").foregroundStyle(.secondary)
            Text(String(format: "%.2g×", value))
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
        .frame(maxWidth: 260)
    }
}
