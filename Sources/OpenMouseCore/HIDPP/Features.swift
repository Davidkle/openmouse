import Foundation

/// HID++ 2.0 feature IDs used by OpenMouse.
public enum FeatureID {
    public static let root: UInt16 = 0x0000
    public static let featureSet: UInt16 = 0x0001
    public static let deviceInformation: UInt16 = 0x0003
    public static let deviceTypeAndName: UInt16 = 0x0005
    public static let batteryStatus: UInt16 = 0x1000
    public static let unifiedBattery: UInt16 = 0x1004
    public static let reprogControlsV4: UInt16 = 0x1B04
    public static let smartShift: UInt16 = 0x2110
    public static let smartShiftEnhanced: UInt16 = 0x2111
    public static let hiResWheel: UInt16 = 0x2121
    public static let thumbwheel: UInt16 = 0x2150
    public static let adjustableDPI: UInt16 = 0x2201
}

/// Well-known `0x1b04` control IDs.
public enum ControlID {
    public static let middleButton: UInt16 = 0x0052
    public static let backButton: UInt16 = 0x0053
    public static let forwardButton: UInt16 = 0x0056
    public static let tiltLeft: UInt16 = 0x005B
    public static let tiltRight: UInt16 = 0x005D
    public static let gestureButton: UInt16 = 0x00C3
    public static let virtualGestureButton: UInt16 = 0x00D7
    public static let hapticPanel: UInt16 = 0x01A0
    /// The DPI / ModeShift family: MX "Smart Shift" button, "DPI Change", "DPI Switch".
    public static let modeShift: [UInt16] = [0x00C4, 0x00ED, 0x00FD]
    public static let gesture: [UInt16] = [gestureButton, virtualGestureButton]
}

// MARK: - 0x0005 Device type and name

public enum DeviceKind: UInt8, Codable, Sendable {
    case keyboard = 0, remoteControl = 1, numpad = 2, mouse = 3, trackpad = 4, trackball = 5
    case presenter = 6, receiver = 7, headset = 8, webcam = 9, steeringWheel = 10, joystick = 11
    case gamepad = 12, dock = 13, speaker = 14, microphone = 15, illumination = 16
    case unknown = 0xFF

    public var isPointer: Bool { self == .mouse || self == .trackball || self == .trackpad }
}

// MARK: - 0x1b04 Reprogrammable controls

public struct CIDFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let mouse = CIDFlags(rawValue: 1 << 0)
    public static let functionKey = CIDFlags(rawValue: 1 << 1)
    public static let hotkey = CIDFlags(rawValue: 1 << 2)
    public static let fnToggle = CIDFlags(rawValue: 1 << 3)
    public static let reprogrammable = CIDFlags(rawValue: 1 << 4)
    public static let divertable = CIDFlags(rawValue: 1 << 5)
    public static let persistentlyDivertable = CIDFlags(rawValue: 1 << 6)
    public static let virtual = CIDFlags(rawValue: 1 << 7)
    public static let rawXY = CIDFlags(rawValue: 1 << 8)
    public static let forceRawXY = CIDFlags(rawValue: 1 << 9)
    public static let analyticsKeyEvents = CIDFlags(rawValue: 1 << 10)
    public static let rawWheel = CIDFlags(rawValue: 1 << 11)
}

public struct CIDInfo: Hashable, Sendable {
    public var cid: UInt16
    public var taskID: UInt16
    public var flags: CIDFlags
    public var position: UInt8
    public var group: UInt8
    public var groupMask: UInt8

    public init(cid: UInt16, taskID: UInt16, flags: CIDFlags, position: UInt8 = 0, group: UInt8 = 0, groupMask: UInt8 = 0) {
        self.cid = cid
        self.taskID = taskID
        self.flags = flags
        self.position = position
        self.group = group
        self.groupMask = groupMask
    }

    /// `getCidInfo` response.
    public init(payload p: [UInt8]) {
        let p = p.padded(to: 16)
        cid = UInt16(p[0]) << 8 | UInt16(p[1])
        taskID = UInt16(p[2]) << 8 | UInt16(p[3])
        flags = CIDFlags(rawValue: UInt16(p[4]) | UInt16(p[8]) << 8)
        position = p[5]
        group = p[6]
        groupMask = p[7]
    }

    public var isDivertable: Bool { flags.contains(.divertable) }
    public var supportsRawXY: Bool { flags.contains(.rawXY) }
}

/// `setCidReporting` request body. `nil` fields are left unchanged on the device.
public struct CIDReportingChange: Equatable, Sendable {
    public var diverted: Bool?
    public var persistentlyDiverted: Bool?
    public var rawXY: Bool?
    public var forceRawXY: Bool?
    public var remap: UInt16?

    public init(diverted: Bool? = nil, persistentlyDiverted: Bool? = nil, rawXY: Bool? = nil, forceRawXY: Bool? = nil, remap: UInt16? = nil) {
        self.diverted = diverted
        self.persistentlyDiverted = persistentlyDiverted
        self.rawXY = rawXY
        self.forceRawXY = forceRawXY
        self.remap = remap
    }

    public func payload(cid: UInt16) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 16)
        p[0] = UInt8(cid >> 8)
        p[1] = UInt8(cid & 0xFF)
        if let v = diverted { p[2] |= 1 << 1; p[2] |= v ? 1 : 0 }
        if let v = persistentlyDiverted { p[2] |= 1 << 3; p[2] |= (v ? 1 : 0) << 2 }
        if let v = rawXY { p[2] |= 1 << 5; p[2] |= (v ? 1 : 0) << 4 }
        if let v = forceRawXY { p[2] |= 1 << 7; p[2] |= (v ? 1 : 0) << 6 }
        if let r = remap { p[3] = UInt8(r >> 8); p[4] = UInt8(r & 0xFF) }
        return p
    }
}

/// Unsolicited `0x1b04` events.
public enum ReprogControlsEvent: Equatable, Sendable {
    /// Up to four CIDs currently held. Empty when everything was released.
    case divertedButtons([UInt16])
    case rawXY(dx: Int16, dy: Int16)

    public init?(function: UInt8, payload p: [UInt8]) {
        let p = p.padded(to: 16)
        switch function {
        case 0:
            var cids: [UInt16] = []
            for i in stride(from: 0, to: 8, by: 2) {
                let cid = UInt16(p[i]) << 8 | UInt16(p[i + 1])
                if cid != 0 { cids.append(cid) }
            }
            self = .divertedButtons(cids)
        case 1:
            self = .rawXY(
                dx: Int16(bitPattern: UInt16(p[0]) << 8 | UInt16(p[1])),
                dy: Int16(bitPattern: UInt16(p[2]) << 8 | UInt16(p[3]))
            )
        default:
            return nil
        }
    }
}

// MARK: - 0x2150 Thumbwheel

public struct ThumbwheelInfo: Equatable, Sendable {
    public var nativeResolution: UInt16
    public var divertedResolution: UInt16
    /// `true` when positive rotation means right / front (`default_dir` = 1).
    public var positiveIsRightOrFront: Bool
    public var supportsSingleTap: Bool

    public init(payload p: [UInt8]) {
        let p = p.padded(to: 16)
        nativeResolution = UInt16(p[0]) << 8 | UInt16(p[1])
        divertedResolution = UInt16(p[2]) << 8 | UInt16(p[3])
        positiveIsRightOrFront = p[4] & 1 == 1
        supportsSingleTap = p[5] & (1 << 3) != 0
    }
}

public struct ThumbwheelEvent: Equatable, Sendable {
    public var rotation: Int16
    /// 0 inactive, 1 start, 2 active, 3 stop.
    public var rotationStatus: UInt8
    public var touch: Bool
    /// Raw single-tap bit. Firmware also sets it on every report while the
    /// wheel turns, so use `isTap` instead.
    public var singleTap: Bool

    public init(payload p: [UInt8]) {
        let p = p.padded(to: 16)
        rotation = Int16(bitPattern: UInt16(p[0]) << 8 | UInt16(p[1]))
        rotationStatus = p[4]
        touch = p[5] & (1 << 1) != 0
        singleTap = p[5] & (1 << 3) != 0
    }

    /// A real tap: the tap bit on a report with no rotation in progress.
    public var isTap: Bool { singleTap && rotation == 0 && rotationStatus == 0 }
}

// MARK: - 0x2110 / 0x2111 SmartShift

public enum WheelMode: UInt8, Codable, Sendable {
    case freespin = 1
    case ratchet = 2
}

public struct SmartShiftStatus: Equatable, Sendable {
    public var mode: WheelMode
    /// Speed threshold above which the wheel disengages to free-spin.
    /// `0xFF` means the ratchet never disengages (SmartShift off).
    public var autoDisengage: UInt8

    public init(mode: WheelMode, autoDisengage: UInt8) {
        self.mode = mode
        self.autoDisengage = autoDisengage
    }

    public init?(payload p: [UInt8]) {
        let p = p.padded(to: 16)
        guard let mode = WheelMode(rawValue: p[0]) else { return nil }
        self.mode = mode
        autoDisengage = p[1]
    }
}

// MARK: - 0x2201 Adjustable DPI

public enum DPIList {
    /// Parse a `getSensorDpiList` payload (bytes after the sensor index).
    /// Values are big-endian u16s terminated by 0. A value with the top three
    /// bits set (`0b111x_xxxx`) is a range step: the list continues from the
    /// previous value in increments of `value & 0x1fff` up to the next value.
    public static func parse(_ bytes: [UInt8]) -> [Int] {
        var values: [Int] = []
        var offset = 0
        while offset + 1 < bytes.count {
            let value = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            if value == 0 { break }
            if value >> 13 == 0b111 {
                let step = value & 0x1FFF
                guard step > 0, offset + 3 < bytes.count, let start = values.last else { return [] }
                let last = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                guard last >= start else { return [] }
                var next = start + step
                while next < last {
                    values.append(next)
                    next += step
                }
                values.append(last)
                offset += 4
            } else {
                values.append(value)
                offset += 2
            }
        }
        return Array(Set(values)).sorted()
    }
}

// MARK: - Battery

public enum ChargeState: String, Codable, Sendable {
    case discharging, charging, full, unknown
}

public struct BatteryStatus: Equatable, Sendable {
    public var percent: Int?
    public var state: ChargeState

    public init(percent: Int?, state: ChargeState) {
        self.percent = percent
        self.state = state
    }

    /// `0x1004` Unified Battery `get_status` (function 1) payload or event.
    public static func unified(_ p: [UInt8]) -> BatteryStatus {
        let p = p.padded(to: 16)
        let percent: Int?
        if p[0] > 0 && p[0] <= 100 {
            percent = Int(p[0])
        } else {
            // Devices without state-of-charge report only a level bitmask.
            switch p[1] {
            case let l where l & 0x08 != 0: percent = 90
            case let l where l & 0x04 != 0: percent = 50
            case let l where l & 0x02 != 0: percent = 20
            case let l where l & 0x01 != 0: percent = 5
            default: percent = nil
            }
        }
        let state: ChargeState
        switch p[2] {
        case 0: state = .discharging
        case 1, 2: state = .charging
        case 3: state = .full
        default: state = .unknown
        }
        return BatteryStatus(percent: percent, state: state)
    }

    /// `0x1000` Battery Status `get_battery_level_status` (function 0) payload or event.
    public static func legacy(_ p: [UInt8]) -> BatteryStatus {
        let p = p.padded(to: 16)
        let state: ChargeState
        switch p[2] {
        case 0: state = .discharging
        case 1, 2: state = .charging
        case 3: state = .full
        default: state = .unknown
        }
        return BatteryStatus(percent: p[0] == 0 ? nil : Int(p[0]), state: state)
    }
}

extension Array where Element == UInt8 {
    func padded(to count: Int) -> [UInt8] {
        self.count >= count ? self : self + [UInt8](repeating: 0, count: count - self.count)
    }
}
