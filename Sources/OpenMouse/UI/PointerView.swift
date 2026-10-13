import OpenMouseCore
import SwiftUI

struct PointerView: View {
    let device: LogiDevice?
    @Environment(ConfigStore.self) private var store
    @Environment(RemapEngine.self) private var engine
    @State private var draft: Double = 1600
    @State private var newPreset = 2400

    private var options: [Int] {
        guard let device, !device.dpiOptions.isEmpty else { return Array(stride(from: 200, through: 8000, by: 50)) }
        return device.dpiOptions
    }

    private var available: Bool { device?.ready == true && device?.hasDPI == true }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(snap(draft))")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("DPI").foregroundStyle(.secondary)
                        Spacer()
                        if let current = device?.dpi {
                            Text("Device: \(current)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Slider(value: $draft, in: Double(options.first ?? 200)...Double(options.last ?? 8000)) { editing in
                        if !editing, let device { engine.setDPI(snap(draft), on: device) }
                    }
                    .labelsHidden()
                    HStack {
                        Text("\(options.first ?? 200)")
                        Spacer()
                        Text("\(options.last ?? 8000)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .disabled(!available)
            } header: {
                Text("Pointer Speed (DPI)")
            } footer: {
                if !available {
                    Text(device == nil ? "Connect a mouse to change its DPI." : "This mouse doesn't support adjustable DPI over HID++.")
                } else {
                    Text("macOS tracking speed in System Settings still applies on top of this.")
                }
            }

            if let device {
                Section {
                    let presets = store.config.deviceSettings(for: device.name).dpiPresets
                    ForEach(presets, id: \.self) { value in
                        HStack {
                            Text("\(value) DPI").monospacedDigit()
                            Spacer()
                            Button("Use") { engine.setDPI(value, on: device); draft = Double(value) }
                                .controlSize(.small)
                            Button {
                                store.updateDevice(device.name) { $0.dpiPresets.removeAll { $0 == value } }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("DPI", value: $newPreset, format: .number)
                            .frame(width: 90)
                        Button("Add Preset") {
                            let value = snap(Double(newPreset))
                            store.updateDevice(device.name) {
                                if !$0.dpiPresets.contains(value) { $0.dpiPresets.append(value); $0.dpiPresets.sort() }
                            }
                        }
                    }
                } header: {
                    Text("DPI Presets")
                } footer: {
                    Text("Assign “Cycle DPI Presets” to a button (for example the Mode Shift button) to step through these.")
                }
                .disabled(!available)
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = Double(device?.dpi ?? store.config.deviceSettings(for: device?.name ?? "").dpi ?? 1600) }
        .onChange(of: device?.dpi) { _, dpi in if let dpi { draft = Double(dpi) } }
    }

    private func snap(_ value: Double) -> Int {
        options.min { abs(Double($0) - value) < abs(Double($1) - value) } ?? Int(value)
    }
}
