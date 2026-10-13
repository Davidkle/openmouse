import AppKit
import CoreGraphics
import OpenMouseCore
import os

private let tapLog = Logger(subsystem: "dev.openmouse", category: "tap")

/// Work the tap hands to the main thread.
enum TapCommand {
    case perform(Action)
    case hold(Action, down: Bool)
}

/// Intercepts mouse buttons the OS already sees (middle / back / forward) and
/// the main scroll wheel, on a dedicated thread so a busy UI never lags input.
final class EventTap: @unchecked Sendable {
    /// Stamped into `eventSourceUserData` on every event we synthesize so the
    /// tap never re-processes its own output.
    static let syntheticMarker: Int64 = 0x4F50_4D53

    struct Snapshot {
        var config = Config()
        var frontmostBundleID: String?
    }

    var dispatch: ((TapCommand) -> Void)?

    private let lock = NSLock()
    private var snapshot = Snapshot()

    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    // Tap-thread-only state.
    private enum Held {
        case swallow
        case mirror(Action)
        case gesture(SwipeAccumulator, GestureActions)
    }
    private var held: [Int64: Held] = [:]
    private var senderCache: [UInt64: SystemSPI.SenderInfo] = [:]
    private var lineRemainder: (v: Double, h: Double) = (0, 0)

    var isRunning: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func update(_ snapshot: Snapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    private func current() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    // MARK: Lifecycle

    /// Create the tap. Fails without Accessibility permission.
    func start() -> Bool {
        guard port == nil else { return true }
        let types: [CGEventType] = [.otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
                                    .mouseMoved, .leftMouseDragged, .rightMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            },
            userInfo: refcon
        ) else {
            tapLog.error("CGEvent.tapCreate failed (Accessibility permission missing?)")
            return false
        }
        self.port = port
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "OpenMouse event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        self.thread = thread
        tapLog.info("Event tap started")
        return true
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let runLoop { CFRunLoopStop(runLoop) }
        port = nil
        runLoop = nil
        thread = nil
    }

    // MARK: Callback

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keep = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Button-ups may have been missed while disabled: release anything
            // we're holding instead of leaving it stuck.
            for state in held.values {
                if case let .mirror(action) = state { dispatch?(.hold(action, down: false)) }
            }
            held.removeAll()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return keep
        }
        if event.getIntegerValueField(.eventSourceUserData) == EventTap.syntheticMarker {
            return keep
        }
        let snap = current()

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            trackGestures(event)
            if type == .otherMouseDragged, let state = held[event.getIntegerValueField(.mouseEventButtonNumber)] {
                if case let .mirror(.mouse(target)) = state {
                    // Remapped to another mouse button: drag as that button.
                    switch target {
                    case .left: event.type = .leftMouseDragged
                    case .right: event.type = .rightMouseDragged
                    default: event.type = .otherMouseDragged
                    }
                    event.setIntegerValueField(.mouseEventButtonNumber, value: target.buttonNumber)
                } else {
                    // The button's down was swallowed; report plain motion instead.
                    event.type = .mouseMoved
                }
            }
            return keep
        case .otherMouseDown:
            return buttonDown(event, snap) ? nil : keep
        case .otherMouseUp:
            return buttonUp(event) ? nil : keep
        case .scrollWheel:
            return scroll(event, snap) ? nil : keep
        default:
            return keep
        }
    }

    private func remappable(_ event: CGEvent, _ snap: Snapshot) -> Bool {
        guard !snap.config.general.paused else { return false }
        guard let sender = SystemSPI.senderID(of: event) else {
            return !snap.config.general.onlyLogitechDevices
        }
        let info: SystemSPI.SenderInfo
        if let cached = senderCache[sender] {
            info = cached
        } else {
            info = SystemSPI.senderInfo(sender)
            senderCache[sender] = info
        }
        if info.isTrackpad { return false }
        return snap.config.general.onlyLogitechDevices ? info.isLogitech : true
    }

    /// Returns true when the event should be swallowed.
    private func buttonDown(_ event: CGEvent, _ snap: Snapshot) -> Bool {
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        guard let button = ButtonID.fromOSButtonNumber(number), remappable(event, snap) else { return false }
        switch snap.config.binding(for: button, app: snap.frontmostBundleID) {
        case .single(.systemDefault):
            return false
        case .single(.disabled):
            held[number] = .swallow
        case let .single(action):
            if case .mouse = action {
                held[number] = .mirror(action)
                dispatch?(.hold(action, down: true))
            } else {
                held[number] = .swallow
                dispatch?(.perform(action))
            }
        case let .gestures(actions):
            var acc = SwipeAccumulator()
            acc.begin()
            held[number] = .gesture(acc, actions)
        }
        return true
    }

    private func buttonUp(_ event: CGEvent) -> Bool {
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        guard let state = held.removeValue(forKey: number) else { return false }
        switch state {
        case .swallow:
            break
        case let .mirror(action):
            dispatch?(.hold(action, down: false))
        case .gesture(var acc, let actions):
            if acc.end() { dispatch?(.perform(actions.click)) }
        }
        return true
    }

    private func trackGestures(_ event: CGEvent) {
        guard !held.isEmpty else { return }
        let dx = Int(event.getIntegerValueField(.mouseEventDeltaX))
        let dy = Int(event.getIntegerValueField(.mouseEventDeltaY))
        guard dx != 0 || dy != 0 else { return }
        for (number, state) in held {
            guard case .gesture(var acc, let actions) = state else { continue }
            if let direction = acc.accumulate(dx: dx, dy: dy) {
                dispatch?(.perform(actions[direction]))
            }
            held[number] = .gesture(acc, actions)
        }
    }

    // MARK: Scroll

    private func scroll(_ event: CGEvent, _ snap: Snapshot) -> Bool {
        // Continuous events come from trackpads / Magic Mouse, never a wheel.
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              remappable(event, snap) else { return false }

        let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let fixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let vertical = fixed != 0 ? fixed : Double(lines)
        if vertical != 0 {
            let natural = UserDefaults.standard.bool(forKey: "com.apple.swipescrolldirection")
            let physicallyUp = natural ? vertical < 0 : vertical > 0
            let button: ButtonID = physicallyUp ? .wheelUp : .wheelDown
            let binding = snap.config.binding(for: button, app: snap.frontmostBundleID)
            if binding.intercepts {
                if case let .single(action) = binding, action != .disabled {
                    dispatch?(.perform(action))
                }
                return true
            }
        }

        let s = snap.config.scroll
        let vFactor = (s.invertVertical ? -1.0 : 1.0) * s.verticalSpeed
        let hFactor = (s.invertHorizontal ? -1.0 : 1.0) * s.horizontalSpeed
        if vFactor != 1 { scale(event, axis: 1, by: vFactor, remainder: &lineRemainder.v) }
        if hFactor != 1 { scale(event, axis: 2, by: hFactor, remainder: &lineRemainder.h) }
        return false
    }

    private func scale(_ event: CGEvent, axis: Int, by factor: Double, remainder: inout Double) {
        let (lineField, fixedField, pointField): (CGEventField, CGEventField, CGEventField) = axis == 1
            ? (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1)
            : (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2)
        let lines = event.getIntegerValueField(lineField)
        let fixed = event.getDoubleValueField(fixedField)
        let points = event.getIntegerValueField(pointField)
        guard lines != 0 || fixed != 0 || points != 0 else { return }

        // Write order matters: the last-written line field becomes canonical and
        // precision is recomputed from it, so write lines, then fixed, then points.
        if lines != 0 {
            // Carry fractional lines so slow speeds still scroll, just less often.
            let exact = Double(lines) * factor + remainder
            var whole = exact.rounded(.towardZero)
            if whole == 0, abs(factor) >= 1 { whole = exact.sign == .minus ? -1 : 1 }
            remainder = abs(factor) < 1 ? exact - whole : 0
            event.setIntegerValueField(lineField, value: Int64(whole))
        }
        if fixed != 0 { event.setDoubleValueField(fixedField, value: fixed * factor) }
        if points != 0 { event.setIntegerValueField(pointField, value: Int64((Double(points) * factor).rounded())) }
    }
}
