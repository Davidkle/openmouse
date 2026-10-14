import Foundation

/// Bindings that apply while a specific app is frontmost. Entries override the
/// global bindings; controls without an entry inherit them.
public struct AppProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var bundleID: String
    public var name: String
    public var appPath: String?
    public var bindings: [ButtonID: ButtonBinding]

    public init(id: UUID = UUID(), bundleID: String, name: String, appPath: String? = nil, bindings: [ButtonID: ButtonBinding] = [:]) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.appPath = appPath
        self.bindings = bindings
    }
}

public struct ScrollSettings: Codable, Hashable, Sendable {
    /// Reverse the main wheel independently of the system "natural scrolling" setting.
    public var invertVertical = false
    public var invertHorizontal = false
    /// Multiplier applied to main-wheel scroll distance.
    public var verticalSpeed = 1.0
    public var horizontalSpeed = 1.0
    /// Reverse the thumb wheel (done in firmware when the thumb wheel isn't remapped).
    public var invertThumbwheel = false
    /// Thumb-wheel scroll speed. Anything other than 1 diverts the thumb wheel.
    public var thumbwheelSpeed = 1.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScrollSettings()
        invertVertical = try c.decodeIfPresent(Bool.self, forKey: .invertVertical) ?? d.invertVertical
        invertHorizontal = try c.decodeIfPresent(Bool.self, forKey: .invertHorizontal) ?? d.invertHorizontal
        verticalSpeed = try c.decodeIfPresent(Double.self, forKey: .verticalSpeed) ?? d.verticalSpeed
        horizontalSpeed = try c.decodeIfPresent(Double.self, forKey: .horizontalSpeed) ?? d.horizontalSpeed
        invertThumbwheel = try c.decodeIfPresent(Bool.self, forKey: .invertThumbwheel) ?? d.invertThumbwheel
        thumbwheelSpeed = try c.decodeIfPresent(Double.self, forKey: .thumbwheelSpeed) ?? d.thumbwheelSpeed
    }
}

public struct SmartShiftSettings: Codable, Hashable, Sendable {
    public var enabled = true
    /// 1...50; higher means the wheel needs a faster flick to free-spin.
    public var sensitivity = 12
    /// Mode used when SmartShift is disabled.
    public var fixedMode: WheelMode = .ratchet

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SmartShiftSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        sensitivity = try c.decodeIfPresent(Int.self, forKey: .sensitivity) ?? d.sensitivity
        fixedMode = try c.decodeIfPresent(WheelMode.self, forKey: .fixedMode) ?? d.fixedMode
    }

    /// The `(mode, autoDisengage)` pair to write over HID++ `0x2110`/`0x2111`.
    public var hidppStatus: SmartShiftStatus {
        if enabled {
            return SmartShiftStatus(mode: .ratchet, autoDisengage: UInt8(clamping: max(1, min(50, sensitivity))))
        }
        return SmartShiftStatus(mode: fixedMode, autoDisengage: 0xFF)
    }
}

/// Settings stored per physical device model (keyed by its HID++ name).
public struct DeviceSettings: Codable, Hashable, Sendable {
    public var dpi: Int?
    public var dpiPresets: [Int]
    public var smartShift: SmartShiftSettings?

    public init(dpi: Int? = nil, dpiPresets: [Int] = [800, 1600, 3200], smartShift: SmartShiftSettings? = nil) {
        self.dpi = dpi
        self.dpiPresets = dpiPresets
        self.smartShift = smartShift
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dpi = try c.decodeIfPresent(Int.self, forKey: .dpi)
        dpiPresets = try c.decodeIfPresent([Int].self, forKey: .dpiPresets) ?? [800, 1600, 3200]
        smartShift = try c.decodeIfPresent(SmartShiftSettings.self, forKey: .smartShift)
    }
}

public struct GeneralSettings: Codable, Hashable, Sendable {
    /// Only intercept buttons and scrolling from Logitech devices.
    public var onlyLogitechDevices = true
    public var paused = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GeneralSettings()
        onlyLogitechDevices = try c.decodeIfPresent(Bool.self, forKey: .onlyLogitechDevices) ?? d.onlyLogitechDevices
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? d.paused
    }
}

/// Everything OpenMouse persists. Stored as JSON, local only.
public struct Config: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version = Config.currentVersion
    public var bindings: [ButtonID: ButtonBinding]
    public var appProfiles: [AppProfile]
    public var scroll: ScrollSettings
    public var devices: [String: DeviceSettings]
    public var general: GeneralSettings

    public init(
        bindings: [ButtonID: ButtonBinding] = Config.defaultBindings,
        appProfiles: [AppProfile] = [],
        scroll: ScrollSettings = ScrollSettings(),
        devices: [String: DeviceSettings] = [:],
        general: GeneralSettings = GeneralSettings()
    ) {
        self.bindings = bindings
        self.appProfiles = appProfiles
        self.scroll = scroll
        self.devices = devices
        self.general = general
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Config.currentVersion
        bindings = try c.decodeIfPresent([ButtonID: ButtonBinding].self, forKey: .bindings) ?? Config.defaultBindings
        appProfiles = try c.decodeIfPresent([AppProfile].self, forKey: .appProfiles) ?? []
        scroll = try c.decodeIfPresent(ScrollSettings.self, forKey: .scroll) ?? ScrollSettings()
        devices = try c.decodeIfPresent([String: DeviceSettings].self, forKey: .devices) ?? [:]
        general = try c.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? GeneralSettings()
    }

    /// Fresh-install defaults: everything native except the gesture button,
    /// which does nothing without software, so it gets Options+-style gestures.
    public static let defaultBindings: [ButtonID: ButtonBinding] = [
        .gestureButton: .gestures(.desktopNavigation),
    ]

    public func profile(for bundleID: String?) -> AppProfile? {
        guard let bundleID else { return nil }
        return appProfiles.first { $0.bundleID == bundleID }
    }

    /// The binding in effect for `button` while `bundleID` is frontmost.
    public func binding(for button: ButtonID, app bundleID: String?) -> ButtonBinding {
        if let override = profile(for: bundleID)?.bindings[button] {
            return override
        }
        return bindings[button] ?? .default
    }

    public func deviceSettings(for name: String) -> DeviceSettings {
        devices[name] ?? DeviceSettings()
    }

    public static func decode(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
