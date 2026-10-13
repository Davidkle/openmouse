import Foundation
import Observation
import OpenMouseCore

/// Callbacks from a device into the remapping engine.
@MainActor
protocol LogiDeviceDelegate: AnyObject {
    func device(_ device: LogiDevice, button: ButtonID, pressed: Bool)
    func device(_ device: LogiDevice, rawXY dx: Int, _ dy: Int)
    func device(_ device: LogiDevice, thumbwheelRotation units: Int, tap: Bool)
    func deviceNeedsConfiguration(_ device: LogiDevice)
}

/// A HID++ 2.0 device (mouse) reachable through a transport at a device index.
@MainActor
@Observable
final class LogiDevice: Identifiable {
    let id: String
    @ObservationIgnored let transport: HIDTransport
    let index: UInt8
    @ObservationIgnored weak var delegate: LogiDeviceDelegate?

    private(set) var name: String
    private(set) var kind: DeviceKind = .unknown
    private(set) var connected = true
    private(set) var ready = false
    private(set) var battery: BatteryStatus?
    private(set) var protocolVersion = ""
    private(set) var controls: [CIDInfo] = []
    private(set) var dpiOptions: [Int] = []
    private(set) var dpi: Int?
    private(set) var smartShift: SmartShiftStatus?
    private(set) var thumbwheel: ThumbwheelInfo?
    private(set) var lastError: String?

    var connectionLabel: String {
        if index != HIDPP.directDeviceIndex { return "Receiver (\(transport.productName))" }
        return transport.transportKind.lowercased().contains("bluetooth") ? "Bluetooth" : transport.transportKind
    }

    var hasSmartShift: Bool { features[FeatureID.smartShiftEnhanced] != nil || features[FeatureID.smartShift] != nil }
    var hasDPI: Bool { features[FeatureID.adjustableDPI] != nil }
    var hasThumbwheel: Bool { thumbwheel != nil }

    /// Controls (by ButtonID) this device can divert over HID++.
    var divertableButtons: Set<ButtonID> {
        let cids = Set(controls.filter(\.isDivertable).map(\.cid))
        return Set(ButtonID.allCases.filter { !$0.controlIDs.isEmpty && $0.controlIDs.contains(where: cids.contains) })
    }

    func supportsGestureRawXY(_ button: ButtonID) -> Bool {
        controls.contains { button.controlIDs.contains($0.cid) && $0.supportsRawXY }
    }

    @ObservationIgnored private var features: [UInt16: UInt8] = [:]
    @ObservationIgnored private var appliedDiversions: [UInt16: Bool] = [:]
    /// False until we've written every relevant control once. A control can
    /// still be diverted by a previous run (or Options+) if the device never
    /// power-cycled, so the first apply writes them all.
    @ObservationIgnored private var diversionStateKnown = false
    @ObservationIgnored private var appliedThumbwheel: (divert: Bool, invert: Bool)?
    @ObservationIgnored private(set) var plan = CapturePlan()
    @ObservationIgnored private var pressed: Set<ButtonID> = []
    @ObservationIgnored private var thumbwheelPositiveIsUp = true

    init(transport: HIDTransport, index: UInt8, name: String) {
        self.transport = transport
        self.index = index
        self.name = name
        id = "\(transport.registryID)-\(index)"
    }

    // MARK: Discovery

    /// Feature call, retried on timeout (Bluetooth LE drops reports).
    private func call(_ feature: UInt16, _ function: UInt8, _ params: [UInt8] = [], timeout: TimeInterval = 1, attempts: Int = 3) async throws -> [UInt8] {
        guard let idx = features[feature] else { throw HIDPPError.featureNotSupported(feature) }
        return try await withRetry(attempts) {
            try await self.transport.call(device: self.index, feature: idx, function: function, params: params, timeout: timeout)
        }
    }

    private func withRetry(_ attempts: Int, _ body: () async throws -> [UInt8]) async throws -> [UInt8] {
        var attempt = 1
        while true {
            do {
                return try await body()
            } catch HIDPPError.timeout where attempt < attempts {
                attempt += 1
            }
        }
    }

    /// Ask the root feature for a feature's index on this device.
    private func lookup(_ feature: UInt16) async throws -> UInt8? {
        let p = try await withRetry(3) {
            try await self.transport.call(device: self.index, feature: 0, function: 0, params: [UInt8(feature >> 8), UInt8(feature & 0xFF), 0], timeout: 1)
        }
        return p[0] == 0 ? nil : p[0]
    }

    /// True once `setup()` has read the device's features.
    var isDiscovered: Bool { features.count > 1 }

    /// Re-arm a known device after it reconnects: confirm it answers, then
    /// forget applied state so the next `apply` rewrites everything.
    func reconnect() async throws {
        resetInputState()
        _ = try await transport.call(device: index, feature: 0, function: 1, params: [0, 0, 0x5A], timeout: 1.5)
        forgetAppliedState()
        connected = true
        ready = true
        await refreshBattery()
    }

    private func forgetAppliedState() {
        appliedDiversions = [:]
        diversionStateKnown = false
        appliedThumbwheel = nil
    }

    /// Release anything we reported as held, so a disconnect mid-press can't
    /// leave a synthesized button stuck down.
    func resetInputState() {
        let held = pressed
        pressed = []
        for button in held { delegate?.device(self, button: button, pressed: false) }
    }

    /// Discover features and read device state. Throws when the device isn't reachable.
    func setup(probeTimeout: TimeInterval = 1.5) async throws {
        ready = false
        resetInputState()
        features = [FeatureID.root: 0]
        let ping = try await transport.call(device: index, feature: 0, function: 1, params: [0, 0, 0x5A], timeout: probeTimeout)
        protocolVersion = "\(ping[0]).\(ping[1])"

        for feature in [FeatureID.deviceTypeAndName, FeatureID.unifiedBattery, FeatureID.batteryStatus,
                        FeatureID.reprogControlsV4, FeatureID.smartShiftEnhanced, FeatureID.smartShift,
                        FeatureID.thumbwheel, FeatureID.adjustableDPI, 0x1D4B] {
            if let idx = try? await lookup(feature) { features[feature] = idx }
        }

        if features[FeatureID.deviceTypeAndName] != nil {
            if let count = try? await call(FeatureID.deviceTypeAndName, 0)[0], count > 0 {
                var bytes: [UInt8] = []
                while bytes.count < Int(count) {
                    guard let chunk = try? await call(FeatureID.deviceTypeAndName, 1, [UInt8(bytes.count)]) else { break }
                    bytes += chunk.prefix(Int(count) - bytes.count)
                }
                if let s = String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters), !s.isEmpty {
                    name = s
                }
            }
            if let t = try? await call(FeatureID.deviceTypeAndName, 2) {
                kind = DeviceKind(rawValue: t[0]) ?? .unknown
            }
        }

        await refreshBattery()

        if features[FeatureID.reprogControlsV4] != nil, let count = try? await call(FeatureID.reprogControlsV4, 0)[0] {
            var list: [CIDInfo] = []
            for i in 0..<count {
                if let p = try? await call(FeatureID.reprogControlsV4, 1, [i]) {
                    list.append(CIDInfo(payload: p))
                }
            }
            controls = list
        }

        if features[FeatureID.thumbwheel] != nil, let p = try? await call(FeatureID.thumbwheel, 0) {
            let info = ThumbwheelInfo(payload: p)
            thumbwheel = info
            thumbwheelPositiveIsUp = info.positiveIsRightOrFront
        }

        if hasDPI {
            if let p = try? await call(FeatureID.adjustableDPI, 1, [0]) {
                dpiOptions = DPIList.parse(Array(p[1...]))
            }
            if let p = try? await call(FeatureID.adjustableDPI, 2, [0]) {
                let value = Int(p[1]) << 8 | Int(p[2])
                dpi = value == 0 ? (Int(p[3]) << 8 | Int(p[4])) : value
            }
        }

        await refreshSmartShift()

        forgetAppliedState()
        connected = true
        lastError = nil
        ready = true
    }

    func refreshBattery() async {
        if features[FeatureID.unifiedBattery] != nil, let p = try? await call(FeatureID.unifiedBattery, 1) {
            battery = .unified(p)
        } else if features[FeatureID.batteryStatus] != nil, let p = try? await call(FeatureID.batteryStatus, 0) {
            battery = .legacy(p)
        }
    }

    func refreshSmartShift() async {
        if features[FeatureID.smartShiftEnhanced] != nil, let p = try? await call(FeatureID.smartShiftEnhanced, 1) {
            smartShift = SmartShiftStatus(payload: p)
        } else if features[FeatureID.smartShift] != nil, let p = try? await call(FeatureID.smartShift, 0) {
            smartShift = SmartShiftStatus(payload: p)
        }
    }

    func markDisconnected() {
        resetInputState()
        connected = false
        ready = false
    }

    // MARK: Configuration

    /// Divert / undivert controls so the device matches `plan`. Only changed
    /// controls are written. Returns false if any write failed.
    @discardableResult
    func apply(plan newPlan: CapturePlan) async -> Bool {
        guard ready else { return true }
        plan = newPlan
        let known = Set(controls.map(\.cid))
        let wanted = newPlan.diversions.mapValues(\.rawXY)
        var touched = Set(wanted.keys).union(appliedDiversions.keys)
        let forceAll = !diversionStateKnown
        if forceAll {
            let divertable = Set(controls.filter(\.isDivertable).map(\.cid))
            touched.formUnion(ButtonID.allCases.flatMap(\.controlIDs).filter(divertable.contains))
        }
        touched.formIntersection(known)
        var allSucceeded = true
        for cid in touched.sorted() {
            let want = wanted[cid]
            if !forceAll, appliedDiversions[cid] == want { continue }
            let supportsRaw = controls.first { $0.cid == cid }?.supportsRawXY ?? false
            let change = CIDReportingChange(
                diverted: want != nil,
                rawXY: supportsRaw ? (want ?? false) : nil
            )
            do {
                let echo = try await call(FeatureID.reprogControlsV4, 3, change.payload(cid: cid))
                guard UInt16(echo[0]) << 8 | UInt16(echo[1]) == cid else { throw HIDPPError.malformedResponse }
                appliedDiversions[cid] = want
            } catch {
                allSucceeded = false
                lastError = "Couldn't configure control 0x\(String(cid, radix: 16)): \(error)"
            }
        }
        if allSucceeded { diversionStateKnown = true }
        var thumbOK = true

        if hasThumbwheel {
            let state = (divert: newPlan.divertThumbwheel, invert: newPlan.invertThumbwheel)
            if appliedThumbwheel == nil || appliedThumbwheel! != state {
                do {
                    _ = try await call(FeatureID.thumbwheel, 2, [state.divert ? 1 : 0, state.invert ? 1 : 0, 0])
                    appliedThumbwheel = state
                } catch {
                    thumbOK = false
                    lastError = "Couldn't configure thumb wheel: \(error)"
                }
            }
        }
        return allSucceeded && thumbOK
    }

    /// Return every control to native behavior (used on quit).
    func releaseAll() async {
        await apply(plan: CapturePlan())
    }

    func setDPI(_ value: Int) async {
        guard hasDPI else { return }
        do {
            _ = try await call(FeatureID.adjustableDPI, 3, [0, UInt8(value >> 8), UInt8(value & 0xFF)])
            dpi = value
        } catch {
            lastError = "Couldn't set DPI: \(error)"
        }
    }

    func setSmartShift(_ status: SmartShiftStatus) async {
        do {
            if features[FeatureID.smartShiftEnhanced] != nil {
                _ = try await call(FeatureID.smartShiftEnhanced, 2, [status.mode.rawValue, status.autoDisengage, 0])
            } else if features[FeatureID.smartShift] != nil {
                _ = try await call(FeatureID.smartShift, 1, [status.mode.rawValue, status.autoDisengage, 0])
            } else {
                return
            }
            smartShift = status
        } catch {
            lastError = "Couldn't set SmartShift: \(error)"
        }
    }

    /// Flip between ratchet and free-spin.
    func toggleWheelMode() async {
        await refreshSmartShift()
        guard let current = smartShift else { return }
        let next: WheelMode = current.mode == .ratchet ? .freespin : .ratchet
        await setSmartShift(SmartShiftStatus(mode: next, autoDisengage: current.autoDisengage))
    }

    // MARK: Notifications

    func handle(_ message: HIDPPMessage) {
        guard message.deviceIndex == index else { return }
        let feature = message.featureIndex
        if feature == features[FeatureID.reprogControlsV4] {
            guard let event = ReprogControlsEvent(function: message.function, payload: message.payload) else { return }
            switch event {
            case let .divertedButtons(cids):
                let now = Set(cids.compactMap { plan.button(forCID: $0) })
                for b in pressed.subtracting(now) { delegate?.device(self, button: b, pressed: false) }
                for b in now.subtracting(pressed) { delegate?.device(self, button: b, pressed: true) }
                pressed = now
            case let .rawXY(dx, dy):
                delegate?.device(self, rawXY: Int(dx), Int(dy))
            }
        } else if feature == features[FeatureID.thumbwheel], message.function == 0 {
            let event = ThumbwheelEvent(payload: message.payload)
            let rotation = Int(event.rotation) * (thumbwheelPositiveIsUp ? 1 : -1)
            if rotation != 0 || event.isTap {
                delegate?.device(self, thumbwheelRotation: rotation, tap: event.isTap)
            }
        } else if feature == features[FeatureID.unifiedBattery], message.function == 0 {
            battery = .unified(message.payload)
        } else if feature == features[FeatureID.batteryStatus], message.function == 0 {
            battery = .legacy(message.payload)
        } else if let idx = features[0x1D4B], feature == idx, message.function == 0 {
            // Wireless device status broadcast: the device reconnected and
            // lost its host-side configuration.
            resetInputState()
            forgetAppliedState()
            delegate?.deviceNeedsConfiguration(self)
        }
    }

    /// Divert-state notes for the diagnostics view.
    var diversionSummary: [(cid: UInt16, diverted: Bool, rawXY: Bool)] {
        controls.map { info in
            let applied = appliedDiversions[info.cid]
            return (info.cid, applied != nil, applied ?? false)
        }
    }

    var thumbwheelDiverted: Bool { appliedThumbwheel?.divert ?? false }
}
