import OpenMouseCore
import SwiftUI

struct ScrollingView: View {
    let device: LogiDevice?
    @Environment(ConfigStore.self) private var store
    @Environment(RemapEngine.self) private var engine

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle(isOn: $store.config.scroll.invertVertical) {
                    Text("Reverse scroll direction")
                    Text("Applies only to the mouse, so trackpad natural scrolling is unaffected.")
                }
                LabeledContent("Vertical speed") { SpeedSlider(value: $store.config.scroll.verticalSpeed) }
                Toggle("Reverse horizontal scrolling", isOn: $store.config.scroll.invertHorizontal)
                LabeledContent("Horizontal speed") { SpeedSlider(value: $store.config.scroll.horizontalSpeed) }
            } header: {
                Text("Scroll Wheel")
            }

            Section {
                SmartShiftControls(device: device)
            } header: {
                Text("SmartShift")
            } footer: {
                if let device, device.ready, !device.hasSmartShift {
                    Text("\(device.name) doesn't support SmartShift.")
                }
            }

            Section {
                ForEach([ButtonID.wheelUp, .wheelDown], id: \.self) { b in
                    LabeledContent(b.label) {
                        ActionPicker(
                            action: Binding(
                                get: { if case let .single(a) = store.binding(for: b, profile: nil) { return a }; return .systemDefault },
                                set: { store.setBinding(.single($0), for: b, profile: nil) }
                            ),
                            defaultLabel: "Default (\(b.nativeBehavior))"
                        )
                        .frame(maxWidth: 260)
                    }
                }
            } header: {
                Text("Wheel Actions")
            } footer: {
                Text("Assigning an action to a scroll direction replaces scrolling in that direction, e.g. to use the wheel for volume.")
            }

            if device?.hasThumbwheel ?? true {
                Section("Thumb Wheel") {
                    ThumbwheelEditor(profileID: nil)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SmartShiftControls: View {
    let device: LogiDevice?
    @Environment(ConfigStore.self) private var store
    @Environment(RemapEngine.self) private var engine

    private var settings: SmartShiftSettings {
        guard let device else { return SmartShiftSettings() }
        if let saved = store.config.deviceSettings(for: device.name).smartShift { return saved }
        // Reflect the device's current state until the user changes it.
        var s = SmartShiftSettings()
        if let status = device.smartShift {
            s.enabled = status.mode == .ratchet && status.autoDisengage != 0xFF && status.autoDisengage > 0
            if s.enabled { s.sensitivity = Int(status.autoDisengage) } else { s.fixedMode = status.mode }
        }
        return s
    }

    private var available: Bool { device?.ready == true && device?.hasSmartShift == true }

    var body: some View {
        let s = settings
        Toggle(isOn: Binding(get: { s.enabled }, set: { var n = s; n.enabled = $0; update(n) })) {
            Text("Enable SmartShift")
            Text("The wheel switches from ratchet to free-spin when you scroll fast.")
        }
        .disabled(!available)
        if s.enabled {
            LabeledContent("Sensitivity") {
                HStack {
                    Text("Low").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(s.sensitivity) }, set: { var n = s; n.sensitivity = Int($0); update(n) }),
                           in: 1...50, step: 1)
                    Text("High").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 260)
            }
            .disabled(!available)
        } else {
            Picker("Wheel mode", selection: Binding(get: { s.fixedMode }, set: { var n = s; n.fixedMode = $0; update(n) })) {
                Text("Ratchet").tag(WheelMode.ratchet)
                Text("Free-spin").tag(WheelMode.freespin)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .disabled(!available)
        }
    }

    private func update(_ settings: SmartShiftSettings) {
        guard let device else { return }
        engine.setSmartShift(settings, on: device)
    }
}
