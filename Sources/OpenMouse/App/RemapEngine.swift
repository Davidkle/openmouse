import AppKit
import ApplicationServices
import Observation
import OpenMouseCore
import os

private let engineLog = Logger(subsystem: "dev.openmouse", category: "engine")

/// Ties config, devices, the event tap and the action executor together.
@MainActor
@Observable
final class RemapEngine: LogiDeviceDelegate {
    let store: ConfigStore
    let devices = DeviceManager()
    @ObservationIgnored let executor = ActionExecutor()
    @ObservationIgnored private let tap = EventTap()

    private(set) var accessibilityGranted = AXIsProcessTrusted()
    private(set) var tapRunning = false
    private(set) var frontmostBundleID: String?
    private(set) var frontmostName: String?
    /// The device that most recently sent a HID++ event, for DPI / SmartShift actions.
    private(set) var activeDeviceID: String?
    /// Last control activity, shown in the UI so users can see presses arrive.
    private(set) var lastActivity: String?

    @ObservationIgnored private var hidGestures: [ButtonID: (SwipeAccumulator, GestureActions)] = [:]
    @ObservationIgnored private var hidHeld: [ButtonID: Action] = [:]
    @ObservationIgnored private var thumbAccumulator = 0
    @ObservationIgnored private var thumbPixelRemainder = 0.0
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(store: ConfigStore) {
        self.store = store
    }

    func start() {
        executor.deviceActionHandler = { [weak self] action in self?.performDeviceAction(action) }
        tap.dispatch = { [weak self] command in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.run(command) }
            }
        }
        store.onChange = { [weak self] old in self?.configChanged(from: old) }

        devices.delegate = self
        devices.onDeviceReady = { [weak self] device in
            guard let self else { return }
            Task { await self.configure(device, applyDeviceSettings: true) }
        }
        devices.start()

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontmostChanged(app) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.devices.rescan() }
        })
        frontmostChanged(NSWorkspace.shared.frontmostApplication)

        startTapWhenTrusted()
    }

    func shutdown() async {
        tap.stop()
        await devices.stop()
    }

    // MARK: Permissions

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        startTapWhenTrusted()
    }

    private func startTapWhenTrusted() {
        accessibilityGranted = AXIsProcessTrusted()
        if accessibilityGranted, tap.start() {
            tapRunning = true
            permissionTimer?.invalidate()
            permissionTimer = nil
            pushSnapshot()
            return
        }
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startTapWhenTrusted() }
        }
    }

    // MARK: Config

    private func pushSnapshot() {
        tap.update(.init(config: store.config, frontmostBundleID: frontmostBundleID))
    }

    private func configChanged(from old: Config) {
        pushSnapshot()
        let new = store.config
        Task {
            for device in devices.devices where device.ready {
                await configure(device, applyDeviceSettings: old.devices[device.name] != new.devices[device.name])
            }
        }
    }

    private func frontmostChanged(_ app: NSRunningApplication?) {
        let bundleID = app?.bundleIdentifier
        guard bundleID != Bundle.main.bundleIdentifier || frontmostBundleID == nil else {
            // Keep the previous app's profile while OpenMouse itself is in front.
            return
        }
        let changed = bundleID != frontmostBundleID
        frontmostBundleID = bundleID
        frontmostName = app?.localizedName
        pushSnapshot()
        // Diversion only differs between apps when some app profile exists.
        if changed, !store.config.appProfiles.isEmpty {
            Task {
                for device in devices.devices where device.ready {
                    await configure(device, applyDeviceSettings: false)
                }
            }
        }
    }

    func configure(_ device: LogiDevice, applyDeviceSettings: Bool) async {
        // Retry with backoff: devices sometimes reject writes right after
        // reconnecting, and a missed write leaves a control on native behavior.
        for delay in [0.0, 0.5, 1.0, 2.0] {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard device.ready else { return }
            let plan = CapturePlan.make(config: store.config, app: frontmostBundleID,
                                        controls: device.controls, hasThumbwheel: device.hasThumbwheel)
            if await device.apply(plan: plan) { break }
        }
        guard applyDeviceSettings else { return }
        let settings = store.config.deviceSettings(for: device.name)
        if let dpi = settings.dpi, dpi != device.dpi {
            await device.setDPI(dpi)
        }
        if let smartShift = settings.smartShift, device.hasSmartShift, device.smartShift != smartShift.hidppStatus {
            await device.setSmartShift(smartShift.hidppStatus)
        }
    }

    func deviceNeedsConfiguration(_ device: LogiDevice) {
        Task {
            // The device occasionally rejects feature writes right at reconnect.
            try? await Task.sleep(for: .milliseconds(200))
            await configure(device, applyDeviceSettings: true)
        }
    }

    // MARK: Event-tap commands

    private func run(_ command: TapCommand) {
        switch command {
        case let .perform(action):
            executor.perform(action)
        case let .hold(action, down):
            _ = executor.setHeld(action, down: down)
        }
    }

    // MARK: HID++ events

    func device(_ device: LogiDevice, button: ButtonID, pressed: Bool) {
        activeDeviceID = device.id
        lastActivity = "\(button.label) \(pressed ? "pressed" : "released")"
        let binding = store.config.binding(for: button, app: frontmostBundleID)
        if pressed {
            switch binding {
            case .single(.systemDefault), .single(.disabled):
                break
            case let .single(action):
                if executor.setHeld(action, down: true) {
                    hidHeld[button] = action
                } else {
                    executor.perform(action)
                }
            case let .gestures(actions):
                var acc = SwipeAccumulator()
                acc.begin()
                hidGestures[button] = (acc, actions)
            }
        } else {
            if let action = hidHeld.removeValue(forKey: button) {
                _ = executor.setHeld(action, down: false)
            }
            if case (var acc, let actions)? = hidGestures.removeValue(forKey: button), acc.end() {
                executor.perform(actions.click)
            }
        }
    }

    func device(_ device: LogiDevice, rawXY dx: Int, _ dy: Int) {
        for (button, entry) in hidGestures {
            var (acc, actions) = entry
            if let direction = acc.accumulate(dx: dx, dy: dy) {
                lastActivity = "\(button.label) gesture \(direction.rawValue)"
                executor.perform(actions[direction])
            }
            hidGestures[button] = (acc, actions)
        }
    }

    func device(_ device: LogiDevice, thumbwheelRotation units: Int, tap: Bool) {
        activeDeviceID = device.id
        let config = store.config
        if tap {
            lastActivity = "Thumb wheel tapped"
            if case let .single(action) = config.binding(for: .thumbwheelTap, app: frontmostBundleID) {
                executor.perform(action)
            }
        }
        guard units != 0 else { return }
        let signed = config.scroll.invertThumbwheel ? -units : units
        let button: ButtonID = signed > 0 ? .thumbwheelUp : .thumbwheelDown
        let binding = config.binding(for: button, app: frontmostBundleID)
        let resolution = Double(device.thumbwheel?.divertedResolution ?? 120)
        let nativeResolution = Double(device.thumbwheel?.nativeResolution ?? 18)

        // Pinch zoom streams with the wheel: one rotation zooms about e×.
        if case let .single(.standard(action)) = binding, let direction = action.pinchDirection {
            thumbAccumulator = 0
            executor.magnify(by: direction * Double(abs(signed)) / resolution * config.scroll.thumbwheelSpeed)
            return
        }
        if case let .single(action) = binding, action.intercepts {
            // Discrete actions fire once per "notch" (~1/12 rotation).
            thumbAccumulator += signed
            let step = max(1, Int(resolution / 12))
            while abs(thumbAccumulator) >= step {
                let direction = thumbAccumulator > 0 ? 1 : -1
                thumbAccumulator -= direction * step
                let notch = config.binding(for: direction > 0 ? .thumbwheelUp : .thumbwheelDown, app: frontmostBundleID)
                if case let .single(a) = notch { executor.perform(a) }
            }
            return
        }
        // Default: smooth horizontal scroll ("up" scrolls left, as in firmware).
        thumbAccumulator = 0
        let pointsPerUnit = 15.0 * nativeResolution / resolution
        let exact = Double(signed) * pointsPerUnit * config.scroll.thumbwheelSpeed + thumbPixelRemainder
        let whole = exact.rounded(.towardZero)
        thumbPixelRemainder = exact - whole
        executor.scrollPixels(dx: Int32(whole), dy: 0)
    }

    // MARK: Device actions

    var activeDevice: LogiDevice? {
        devices.devices.first { $0.id == activeDeviceID && $0.ready } ?? devices.devices.first { $0.ready }
    }

    private func performDeviceAction(_ action: Action) {
        guard let device = activeDevice else { return }
        switch action {
        case .standard(.cycleDPI):
            let supported = Set(device.dpiOptions)
            let presets = store.config.deviceSettings(for: device.name).dpiPresets
                .filter { supported.isEmpty || supported.contains($0) }.sorted()
            guard !presets.isEmpty else { return }
            let current = device.dpi ?? 0
            let next = presets.first { $0 > current } ?? presets[0]
            setDPI(next, on: device)
        case let .setDPI(value):
            setDPI(value, on: device)
        case .standard(.toggleSmartShift):
            Task { await device.toggleWheelMode() }
        default:
            break
        }
    }

    func setDPI(_ value: Int, on device: LogiDevice) {
        store.updateDevice(device.name) { $0.dpi = value }
        Task { await device.setDPI(value) }
    }

    func setSmartShift(_ settings: SmartShiftSettings, on device: LogiDevice) {
        store.updateDevice(device.name) { $0.smartShift = settings }
        Task { await device.setSmartShift(settings.hidppStatus) }
    }
}
