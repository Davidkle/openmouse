import AppKit
import CoreGraphics
import OpenMouseCore
import os

private let actionLog = Logger(subsystem: "dev.openmouse", category: "actions")

/// Turns an `Action` into synthesized input or a system call.
@MainActor
final class ActionExecutor {
    /// Device-level actions (DPI, SmartShift) are routed back to the engine.
    var deviceActionHandler: ((Action) -> Void)?

    private let source = CGEventSource(stateID: .hidSystemState)

    /// Fire an action once (press + release).
    func perform(_ action: Action) {
        switch action {
        case .systemDefault, .disabled:
            break
        case let .mouse(button):
            click(button)
        case let .standard(standard):
            perform(standard)
        case let .scroll(direction):
            scroll(direction, lines: 3)
        case let .shortcut(combo):
            press(combo, layoutAware: false)
        case .setDPI:
            deviceActionHandler?(action)
        case let .openApplication(path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
        case let .openURL(string):
            if let url = URL(string: string.contains("://") ? string : "https://\(string)") {
                NSWorkspace.shared.open(url)
            }
        case let .shellCommand(command):
            runShell(command)
        case let .appleScript(source):
            runAppleScript(source)
        case let .typeText(text):
            type(text)
        }
    }

    /// Press-and-hold support: mouse-button actions mirror the physical
    /// button's down/up so dragging works. Returns false for actions that
    /// don't support holding (those should use `perform` on press).
    func setHeld(_ action: Action, down: Bool) -> Bool {
        guard case let .mouse(button) = action else { return false }
        postMouse(button, down: down)
        return true
    }

    private func perform(_ action: StandardAction) {
        if let combo = action.shortcut {
            press(combo, layoutAware: true)
            return
        }
        switch action {
        case .missionControl:
            if !SystemSPI.dockNotification("com.apple.expose.awake") { SystemSPI.postSymbolicHotkey(.missionControl) }
        case .appExpose:
            if !SystemSPI.dockNotification("com.apple.expose.front.awake") { SystemSPI.postSymbolicHotkey(.applicationWindows) }
        case .showDesktop:
            if !SystemSPI.dockNotification("com.apple.showdesktop.awake") { SystemSPI.postSymbolicHotkey(.showDesktop) }
        case .launchpad:
            let apps = URL(fileURLWithPath: "/System/Applications/Apps.app")
            if FileManager.default.fileExists(atPath: apps.path) {
                NSWorkspace.shared.openApplication(at: apps, configuration: .init())
            } else if !SystemSPI.dockNotification("com.apple.launchpad.toggle") {
                SystemSPI.postSymbolicHotkey(.launchpad)
            }
        case .previousDesktop:
            if !SystemSPI.postSymbolicHotkey(.moveLeftSpace) {
                press(KeyCombo(keyCode: KeyCodes.leftArrow, modifiers: [.control, .function]), layoutAware: false)
            }
        case .nextDesktop:
            if !SystemSPI.postSymbolicHotkey(.moveRightSpace) {
                press(KeyCombo(keyCode: KeyCodes.rightArrow, modifiers: [.control, .function]), layoutAware: false)
            }
        case .notificationCenter:
            SystemSPI.postSymbolicHotkey(.notificationCenter)
        case .screenshot:
            SystemSPI.postSymbolicHotkey(.screenshotToFile)
        case .captureRegion:
            SystemSPI.postSymbolicHotkey(.selectionToClipboard)
        case .screenshotToolbar:
            SystemSPI.postSymbolicHotkey(.screenshotToolbar)
        case .sleep:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["sleepnow"]
            try? process.run()
        case .playPause: mediaKey(16)
        case .nextTrack: mediaKey(17)
        case .previousTrack: mediaKey(18)
        case .volumeUp: mediaKey(0)
        case .volumeDown: mediaKey(1)
        case .mute: mediaKey(7)
        case .brightnessUp: mediaKey(2)
        case .brightnessDown: mediaKey(3)
        case .pinchZoomIn, .pinchZoomOut:
            magnify(by: Self.pinchStep * (action.pinchDirection ?? 0))
        case .cycleDPI, .toggleSmartShift:
            deviceActionHandler?(.standard(action))
        default:
            actionLog.warning("Unhandled action \(action.rawValue, privacy: .public)")
        }
    }

    // MARK: Keyboard

    func press(_ combo: KeyCombo, layoutAware: Bool) {
        var code = combo.keyCode
        if layoutAware, combo.keyLabel.count == 1, let ch = combo.keyLabel.first, ch.isLetter || ch.isPunctuation || ch.isSymbol,
           let mapped = KeyboardLayout.keyCode(for: ch) {
            code = mapped
        }
        var flags = CGEventFlags(rawValue: combo.modifiers.cgEventFlags)
        if [KeyCodes.leftArrow, KeyCodes.rightArrow, KeyCodes.upArrow, KeyCodes.downArrow].contains(code) {
            flags.insert(.maskNumericPad)
            flags.insert(.maskSecondaryFn)
        }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            tag(event)
            event.post(tap: .cghidEventTap)
        }
    }

    func type(_ text: String) {
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            let end = min(start + 20, units.count)
            var chunk = Array(units[start..<end])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                tag(event)
                event.post(tap: .cghidEventTap)
            }
            start = end
        }
    }

    private func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let state: Int32 = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                subtype: 8, data1: Int((key << 16) | (state << 8)), data2: -1
            )
            if let cg = event?.cgEvent {
                tag(cg)
                cg.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: Mouse

    private var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    func click(_ button: MouseButton) {
        postMouse(button, down: true)
        postMouse(button, down: false)
    }

    func postMouse(_ button: MouseButton, down: Bool) {
        let (type, cgButton): (CGEventType, CGMouseButton)
        switch button {
        case .left: (type, cgButton) = (down ? .leftMouseDown : .leftMouseUp, .left)
        case .right: (type, cgButton) = (down ? .rightMouseDown : .rightMouseUp, .right)
        case .middle, .back, .forward: (type, cgButton) = (down ? .otherMouseDown : .otherMouseUp, .center)
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: cursor, mouseButton: cgButton) else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: button.buttonNumber)
        tag(event)
        event.post(tap: .cghidEventTap)
    }

    func scroll(_ direction: ScrollDirection, lines: Int32) {
        let (v, h): (Int32, Int32)
        switch direction {
        case .up: (v, h) = (lines, 0)
        case .down: (v, h) = (-lines, 0)
        case .left: (v, h) = (0, lines)
        case .right: (v, h) = (0, -lines)
        }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: v, wheel2: h, wheel3: 0) else { return }
        tag(event)
        event.post(tap: .cghidEventTap)
    }

    /// Smooth pixel scrolling, used for the diverted thumb wheel.
    func scrollPixels(dx: Int32, dy: Int32) {
        guard dx != 0 || dy != 0,
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        tag(event)
        event.post(tap: .cghidEventTap)
    }

    // MARK: Pinch

    /// Magnification one button press zooms by (0.1 = 10%).
    private static let pinchStep = 0.1
    /// A pinch ends once the input has been still this long.
    private static let pinchIdle: TimeInterval = 0.15
    private var pinchEnd: DispatchWorkItem?

    /// Zoom the view under the pointer by posting the trackpad's magnify
    /// gesture. Successive calls extend one pinch, which ends after
    /// `pinchIdle` of quiet, so a spinning wheel reads as a single gesture.
    func magnify(by amount: Double) {
        guard amount != 0 else { return }
        if pinchEnd == nil { postMagnify(0, phase: .began) }
        postMagnify(amount, phase: .changed)
        pinchEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in
            self?.postMagnify(0, phase: .ended)
            self?.pinchEnd = nil
        }
        pinchEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pinchIdle, execute: end)
    }

    /// IOHIDEventPhaseBits.
    private enum PinchPhase: Int64 {
        case began = 1, changed = 2, ended = 4
    }

    /// CGEvent has no public magnify constructor; these are the undocumented
    /// gesture fields a trackpad pinch carries (event type 29 = NSEventTypeGesture,
    /// subtype 8 = kIOHIDEventTypeZoom).
    private func postMagnify(_ amount: Double, phase: PinchPhase) {
        guard let event = CGEvent(source: source), let gesture = CGEventType(rawValue: 29),
              let subtype = CGEventField(rawValue: 110), let magnification = CGEventField(rawValue: 113),
              let phaseField = CGEventField(rawValue: 132) else { return }
        event.type = gesture
        event.setIntegerValueField(subtype, value: 8)
        event.setIntegerValueField(phaseField, value: phase.rawValue)
        event.setDoubleValueField(magnification, value: amount)
        tag(event)
        event.post(tap: .cghidEventTap)
    }

    private func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticMarker)
    }

    // MARK: Scripts

    private func runShell(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { actionLog.error("Shell command failed: \(error.localizedDescription, privacy: .public)") }
    }

    private func runAppleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { actionLog.error("AppleScript error: \(error, privacy: .public)") }
    }
}
