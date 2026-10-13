import AppKit
import OpenMouseCore
import SwiftUI

/// A pop-up menu for choosing an action, with sheets for parameterized ones.
struct ActionPicker: View {
    @Binding var action: Action
    var allowDefault = true
    var defaultLabel = "Default"

    @State private var editing: CustomKind?

    enum CustomKind: String, Identifiable {
        case shortcut, application, url, text, shell, appleScript, dpi
        var id: String { rawValue }
    }

    var body: some View {
        Menu {
            if allowDefault {
                Button { action = .systemDefault } label: { Label(defaultLabel, systemImage: Action.systemDefault.symbol) }
            }
            Button { action = .disabled } label: { Label(Action.disabled.label, systemImage: Action.disabled.symbol) }
            Divider()
            ForEach(Action.catalog.indices, id: \.self) { i in
                Menu(Action.catalog[i].0.rawValue) {
                    ForEach(Action.catalog[i].1, id: \.self) { a in
                        Button { action = a } label: { Label(a.label, systemImage: a.symbol) }
                    }
                }
            }
            Divider()
            Button("Keyboard Shortcut…") { editing = .shortcut }
            Button("Open Application…") { chooseApplication() }
            Button("Open Website…") { editing = .url }
            Button("Type Text…") { editing = .text }
            Button("Set DPI…") { editing = .dpi }
            Menu("Advanced") {
                Button("Run Shell Command…") { editing = .shell }
                Button("Run AppleScript…") { editing = .appleScript }
            }
        } label: {
            // Drawn by hand: the bordered menu style sizes to its label, so
            // pickers stacked in rows would all end up different widths.
            HStack(spacing: 6) {
                Label(displayLabel, systemImage: action.symbol)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: $editing) { kind in
            CustomActionSheet(kind: kind, initial: action) { result in
                if let result { action = result }
                editing = nil
            }
        }
    }

    private var displayLabel: String {
        action == .systemDefault ? defaultLabel : action.label
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            action = .openApplication(path: url.path)
        }
    }
}

private struct CustomActionSheet: View {
    let kind: ActionPicker.CustomKind
    let initial: Action
    let done: (Action?) -> Void

    @State private var text = ""
    @State private var combo: KeyCombo?
    @State private var dpi = 1600

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            switch kind {
            case .shortcut:
                ShortcutRecorder(combo: $combo)
                Text("Click the field, then press the key combination.").font(.caption).foregroundStyle(.secondary)
            case .url:
                TextField("https://example.com", text: $text).textFieldStyle(.roundedBorder)
            case .text:
                TextField("Text to type", text: $text, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
            case .shell:
                TextField("open -a Terminal", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Text("Runs with /bin/sh -c as your user.").font(.caption).foregroundStyle(.secondary)
            case .appleScript:
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            case .dpi:
                Stepper(value: $dpi, in: 100...16000, step: 50) {
                    TextField("DPI", value: $dpi, format: .number).frame(width: 90).textFieldStyle(.roundedBorder)
                }
            case .application:
                EmptyView()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { done(result) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(result == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: load)
    }

    private var title: String {
        switch kind {
        case .shortcut: return "Keyboard Shortcut"
        case .url: return "Open Website"
        case .text: return "Type Text"
        case .shell: return "Run Shell Command"
        case .appleScript: return "Run AppleScript"
        case .dpi: return "Set DPI"
        case .application: return "Open Application"
        }
    }

    private var result: Action? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .shortcut: return combo.map { .shortcut($0) }
        case .url: return trimmed.isEmpty ? nil : .openURL(trimmed)
        case .text: return text.isEmpty ? nil : .typeText(text)
        case .shell: return trimmed.isEmpty ? nil : .shellCommand(text)
        case .appleScript: return trimmed.isEmpty ? nil : .appleScript(text)
        case .dpi: return .setDPI(dpi)
        case .application: return nil
        }
    }

    private func load() {
        switch initial {
        case let .shortcut(c) where kind == .shortcut: combo = c
        case let .openURL(s) where kind == .url: text = s
        case let .typeText(s) where kind == .text: text = s
        case let .shellCommand(s) where kind == .shell: text = s
        case let .appleScript(s) where kind == .appleScript: text = s
        case let .setDPI(d) where kind == .dpi: dpi = d
        default: break
        }
    }
}

/// Captures the next key press (with modifiers) while focused.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            HStack {
                Image(systemName: "keyboard")
                Text(recording ? "Press a shortcut…" : (combo?.display ?? "Click to record"))
                    .font(.system(.title3, design: .rounded).weight(.medium))
                Spacer()
                if combo != nil && !recording {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .onTapGesture { combo = nil }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(recording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(recording ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags
            var modifiers: KeyCombo.Modifiers = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            let code = event.keyCode
            var label = KeyCodes.name(for: code)
            if !KeyCodes.isSpecial(code), let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                label = chars.uppercased()
            }
            combo = KeyCombo(keyCode: code, modifiers: modifiers, keyLabel: label)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
