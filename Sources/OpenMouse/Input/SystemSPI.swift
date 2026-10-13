import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Private system calls, resolved at runtime so a missing symbol degrades
/// gracefully instead of failing to launch.
enum SystemSPI {
    private static let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)

    private static func symbol<T>(_ name: String, in lib: UnsafeMutableRawPointer?, as _: T.Type) -> T? {
        guard let sym = dlsym(lib ?? UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(sym, to: T.self)
    }

    // MARK: Dock

    private typealias CoreDockSendNotification = @convention(c) (CFString, Int32) -> Int32
    private static let coreDockSend = symbol("CoreDockSendNotification", in: handle, as: CoreDockSendNotification.self)

    /// Fire a Dock notification such as `com.apple.expose.awake`.
    @discardableResult
    static func dockNotification(_ name: String) -> Bool {
        guard let send = coreDockSend else { return false }
        return send(name as CFString, 0) == 0
    }

    // MARK: Symbolic hot keys

    enum Hotkey: UInt32 {
        case screenshotToFile = 28
        case selectionToClipboard = 31
        case missionControl = 32
        case applicationWindows = 33
        case showDesktop = 36
        case spotlight = 64
        case moveLeftSpace = 79
        case moveRightSpace = 81
        case launchpad = 160
        case notificationCenter = 163
        case screenshotToolbar = 184
    }

    private typealias GetValue = @convention(c) (UInt32, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt16>, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias IsEnabled = @convention(c) (UInt32) -> Bool
    private typealias SetEnabled = @convention(c) (UInt32, Bool) -> Int32
    private static let getValue = symbol("CGSGetSymbolicHotKeyValue", in: coreGraphics, as: GetValue.self)
        ?? symbol("CGSGetSymbolicHotKeyValue", in: handle, as: GetValue.self)
    private static let isEnabled = symbol("CGSIsSymbolicHotKeyEnabled", in: coreGraphics, as: IsEnabled.self)
        ?? symbol("CGSIsSymbolicHotKeyEnabled", in: handle, as: IsEnabled.self)
    private static let setEnabled = symbol("CGSSetSymbolicHotKeyEnabled", in: coreGraphics, as: SetEnabled.self)
        ?? symbol("CGSSetSymbolicHotKeyEnabled", in: handle, as: SetEnabled.self)

    /// Trigger a system keyboard shortcut by posting whatever key the user has
    /// assigned to it, temporarily enabling it if it's switched off.
    @discardableResult
    static func postSymbolicHotkey(_ hotkey: Hotkey) -> Bool {
        guard let getValue, let isEnabled, let setEnabled else { return false }
        var keyEquivalent: UInt16 = 0
        var virtualKey: UInt16 = 0
        var modifiers: UInt32 = 0
        guard getValue(hotkey.rawValue, &keyEquivalent, &virtualKey, &modifiers) == 0 else { return false }
        let wasEnabled = isEnabled(hotkey.rawValue)
        if !wasEnabled { _ = setEnabled(hotkey.rawValue, true) }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: down) else { continue }
            event.flags = CGEventFlags(rawValue: UInt64(modifiers))
            event.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticMarker)
            event.post(tap: .cgSessionEventTap)
        }
        if !wasEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { _ = setEnabled(hotkey.rawValue, false) }
        }
        return true
    }

    // MARK: Event source device

    private typealias CopyIOHIDEvent = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias GetSenderID = @convention(c) (CFTypeRef) -> UInt64
    private static let copyIOHIDEvent = symbol("CGEventCopyIOHIDEvent", in: coreGraphics, as: CopyIOHIDEvent.self)
    private static let getSenderID = symbol("IOHIDEventGetSenderID", in: iokit, as: GetSenderID.self)

    /// Registry entry ID of the HID service that produced `event`.
    static func senderID(of event: CGEvent) -> UInt64? {
        guard let copy = copyIOHIDEvent, let getSender = getSenderID,
              let hid = copy(event)?.takeRetainedValue() else { return nil }
        let id = getSender(hid)
        return id == 0 ? nil : id
    }

    struct SenderInfo {
        var vendorID: Int?
        var product: String?
        var isLogitech: Bool { vendorID == 0x046D || (product?.localizedCaseInsensitiveContains("logi") ?? false) || (product?.hasPrefix("MX ") ?? false) }
        var isTrackpad: Bool { product?.localizedCaseInsensitiveContains("trackpad") ?? false }
    }

    /// Look up vendor / product for a HID sender by walking the registry.
    static func senderInfo(_ senderID: UInt64) -> SenderInfo {
        guard let matching = IORegistryEntryIDMatching(senderID) else { return SenderInfo() }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return SenderInfo() }
        defer { IOObjectRelease(service) }
        func prop(_ key: String) -> CFTypeRef? {
            IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        }
        let vendor = (prop("VendorID") as? Int) ?? (prop("idVendor") as? Int)
        let product = prop("Product") as? String
        return SenderInfo(vendorID: vendor, product: product)
    }
}

/// Maps characters to key codes for the current keyboard layout, so fixed
/// shortcuts like ⌘C hit the right key on AZERTY, Dvorak, etc.
@MainActor
enum KeyboardLayout {
    private static var cache: [Character: UInt16]?
    private static var observer: NSObjectProtocol?

    static func keyCode(for character: Character) -> UInt16? {
        if observer == nil {
            observer = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { cache = nil } }
        }
        if cache == nil { cache = build() }
        return cache?[Character(character.lowercased())]
    }

    private static func build() -> [Character: UInt16] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var map: [Character: UInt16] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in UInt16(0)..<128 {
                var deadKeys: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
                guard status == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]) else { continue }
                let ch = Character(String(scalar).lowercased())
                if map[ch] == nil { map[ch] = code }
            }
        }
        return map
    }
}
