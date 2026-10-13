import Foundation

/// Which HID++ controls must be diverted to the host for the current bindings.
/// A control is diverted only when its
/// binding leaves the native behavior, so untouched controls keep working
/// even when OpenMouse isn't running.
public struct CapturePlan: Equatable, Sendable {
    public struct Diversion: Equatable, Sendable {
        public var button: ButtonID
        public var rawXY: Bool
    }

    /// Keyed by control ID.
    public var diversions: [UInt16: Diversion] = [:]
    public var divertThumbwheel = false
    /// Firmware-level thumb-wheel inversion, used when it isn't diverted.
    public var invertThumbwheel = false

    public init() {}

    /// Build the plan for a device exposing `controls` (from `0x1b04`).
    public static func make(
        config: Config,
        app bundleID: String?,
        controls: [CIDInfo],
        hasThumbwheel: Bool
    ) -> CapturePlan {
        var plan = CapturePlan()
        guard !config.general.paused else { return plan }
        let byCID = Dictionary(controls.map { ($0.cid, $0) }, uniquingKeysWith: { a, _ in a })

        for button in ButtonID.allCases where !button.controlIDs.isEmpty {
            let binding = config.binding(for: button, app: bundleID)
            guard binding.intercepts else { continue }
            guard let info = button.controlIDs.lazy.compactMap({ byCID[$0] }).first(where: { $0.isDivertable }) else { continue }
            plan.diversions[info.cid] = Diversion(button: button, rawXY: binding.isGesture && info.supportsRawXY)
        }

        if hasThumbwheel {
            let thumbBindings: [ButtonID] = [.thumbwheelUp, .thumbwheelDown, .thumbwheelTap]
            let remapped = thumbBindings.contains { config.binding(for: $0, app: bundleID).intercepts }
            plan.divertThumbwheel = remapped || abs(config.scroll.thumbwheelSpeed - 1) > 0.001
            plan.invertThumbwheel = !plan.divertThumbwheel && config.scroll.invertThumbwheel
        }
        return plan
    }

    /// The button a diverted control ID reports as.
    public func button(forCID cid: UInt16) -> ButtonID? {
        diversions[cid]?.button
    }
}
