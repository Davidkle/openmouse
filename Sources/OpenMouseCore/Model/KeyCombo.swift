import Foundation

/// A recorded keyboard shortcut: a macOS virtual key code plus modifiers.
public struct KeyCombo: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
        public static let function = Modifiers(rawValue: 1 << 4)

        /// `CGEventFlags` raw bits.
        public var cgEventFlags: UInt64 {
            var f: UInt64 = 0
            if contains(.shift) { f |= 0x20000 }
            if contains(.control) { f |= 0x40000 }
            if contains(.option) { f |= 0x80000 }
            if contains(.command) { f |= 0x100000 }
            if contains(.function) { f |= 0x800000 }
            return f
        }

        public init(cgEventFlags f: UInt64) {
            var m: Modifiers = []
            if f & 0x20000 != 0 { m.insert(.shift) }
            if f & 0x40000 != 0 { m.insert(.control) }
            if f & 0x80000 != 0 { m.insert(.option) }
            if f & 0x100000 != 0 { m.insert(.command) }
            self = m
        }

        public var symbols: String {
            var s = ""
            if contains(.function) { s += "fn " }
            if contains(.control) { s += "⌃" }
            if contains(.option) { s += "⌥" }
            if contains(.shift) { s += "⇧" }
            if contains(.command) { s += "⌘" }
            return s
        }
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers
    /// Key name captured at record time (layout-specific), e.g. "C" or "→".
    public var keyLabel: String

    public init(keyCode: UInt16, modifiers: Modifiers, keyLabel: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel ?? KeyCodes.name(for: keyCode)
    }

    public var display: String { modifiers.symbols + keyLabel }
}

/// macOS virtual key codes (ANSI positions, `kVK_*`).
public enum KeyCodes {
    public static let a: UInt16 = 0x00, s: UInt16 = 0x01, f: UInt16 = 0x03, z: UInt16 = 0x06
    public static let x: UInt16 = 0x07, c: UInt16 = 0x08, v: UInt16 = 0x09, w: UInt16 = 0x0D
    public static let q: UInt16 = 0x0C, r: UInt16 = 0x0F, t: UInt16 = 0x11, n: UInt16 = 0x2D
    public static let equal: UInt16 = 0x18, minus: UInt16 = 0x1B, zero: UInt16 = 0x1D
    public static let rightBracket: UInt16 = 0x1E, leftBracket: UInt16 = 0x21
    public static let `return`: UInt16 = 0x24, tab: UInt16 = 0x30, space: UInt16 = 0x31
    public static let delete: UInt16 = 0x33, escape: UInt16 = 0x35
    public static let leftArrow: UInt16 = 0x7B, rightArrow: UInt16 = 0x7C
    public static let downArrow: UInt16 = 0x7D, upArrow: UInt16 = 0x7E

    static let names: [UInt16: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
        0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "O", 0x20: "U",
        0x21: "[", 0x22: "I", 0x23: "P", 0x24: "↩", 0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K",
        0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x30: "⇥",
        0x31: "Space", 0x32: "`", 0x33: "⌫", 0x35: "⎋", 0x60: "F5", 0x61: "F6", 0x62: "F7",
        0x63: "F3", 0x64: "F8", 0x65: "F9", 0x67: "F11", 0x69: "F13", 0x6A: "F16", 0x6B: "F14",
        0x6D: "F10", 0x6F: "F12", 0x71: "F15", 0x72: "Help", 0x73: "↖", 0x74: "⇞", 0x75: "⌦",
        0x76: "F4", 0x77: "↘", 0x78: "F2", 0x79: "⇟", 0x7A: "F1", 0x7B: "←", 0x7C: "→",
        0x7D: "↓", 0x7E: "↑", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
    ]

    public static func name(for keyCode: UInt16) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }

    /// Keys whose label shouldn't be replaced with a layout-translated character.
    public static func isSpecial(_ keyCode: UInt16) -> Bool {
        guard let name = names[keyCode] else { return false }
        return name.count > 1 || "↩⇥⌫⎋↖⇞⌦↘⇟←→↓↑".contains(name)
    }
}
