import Foundation

/// A user-rebindable control on a Logitech mouse.
///
/// Each control is captured one of two ways:
/// - **Event tap**: buttons macOS already sees as mouse buttons (middle, back,
///   forward) and the main wheel. Intercepted with a `CGEventTap`.
/// - **HID++**: controls that are invisible to macOS until diverted over the
///   `0x1b04` reprogrammable-controls feature (gesture button, ModeShift,
///   wheel tilt, haptic panel) or `0x2150` thumbwheel.
public enum ButtonID: String, CaseIterable, Codable, CodingKeyRepresentable, Hashable, Sendable, Identifiable {
    case middleClick
    case back
    case forward
    case wheelTiltLeft
    case wheelTiltRight
    case modeShift
    case gestureButton
    case hapticPanel
    case wheelUp
    case wheelDown
    case thumbwheelUp
    case thumbwheelDown
    case thumbwheelTap

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .middleClick: return "Middle Click"
        case .back: return "Back Button"
        case .forward: return "Forward Button"
        case .wheelTiltLeft: return "Wheel Tilt Left"
        case .wheelTiltRight: return "Wheel Tilt Right"
        case .modeShift: return "Mode Shift Button"
        case .gestureButton: return "Gesture Button"
        case .hapticPanel: return "Haptic Sense Panel"
        case .wheelUp: return "Scroll Up"
        case .wheelDown: return "Scroll Down"
        case .thumbwheelUp: return "Thumb Wheel Up"
        case .thumbwheelDown: return "Thumb Wheel Down"
        case .thumbwheelTap: return "Thumb Wheel Tap"
        }
    }

    /// Name of the built-in behavior when nothing is remapped.
    public var nativeBehavior: String {
        switch self {
        case .middleClick: return "Middle click"
        case .back: return "Back"
        case .forward: return "Forward"
        case .wheelTiltLeft: return "Scroll left"
        case .wheelTiltRight: return "Scroll right"
        case .modeShift: return "Toggle ratchet / free-spin"
        case .gestureButton: return "None"
        case .hapticPanel: return "None"
        case .wheelUp: return "Scroll up"
        case .wheelDown: return "Scroll down"
        case .thumbwheelUp: return "Scroll left"
        case .thumbwheelDown: return "Scroll right"
        case .thumbwheelTap: return "None"
        }
    }

    public var symbol: String {
        switch self {
        case .middleClick: return "computermouse"
        case .back: return "chevron.backward.circle"
        case .forward: return "chevron.forward.circle"
        case .wheelTiltLeft: return "arrow.left.circle"
        case .wheelTiltRight: return "arrow.right.circle"
        case .modeShift: return "gearshape.2"
        case .gestureButton: return "hand.draw"
        case .hapticPanel: return "hand.tap"
        case .wheelUp: return "arrow.up"
        case .wheelDown: return "arrow.down"
        case .thumbwheelUp: return "arrow.up.left"
        case .thumbwheelDown: return "arrow.down.right"
        case .thumbwheelTap: return "hand.point.up"
        }
    }

    /// The action that reproduces the native behavior, for seeding a
    /// gesture's click when switching a button into gesture mode.
    public var nativeAction: Action {
        switch self {
        case .middleClick: return .mouse(.middle)
        case .back: return .mouse(.back)
        case .forward: return .mouse(.forward)
        case .modeShift: return .standard(.toggleSmartShift)
        case .wheelTiltLeft, .thumbwheelUp: return .scroll(.left)
        case .wheelTiltRight, .thumbwheelDown: return .scroll(.right)
        case .wheelUp: return .scroll(.up)
        case .wheelDown: return .scroll(.down)
        case .gestureButton, .hapticPanel, .thumbwheelTap: return .disabled
        }
    }

    /// Captured by the OS event tap rather than HID++.
    public var isEventTapButton: Bool {
        switch self {
        case .middleClick, .back, .forward, .wheelUp, .wheelDown: return true
        default: return false
        }
    }

    /// macOS mouse button number for event-tap buttons (`kCGMouseEventButtonNumber`).
    public var osButtonNumber: Int64? {
        switch self {
        case .middleClick: return 2
        case .back: return 3
        case .forward: return 4
        default: return nil
        }
    }

    public static func fromOSButtonNumber(_ n: Int64) -> ButtonID? {
        switch n {
        case 2: return .middleClick
        case 3: return .back
        case 4: return .forward
        default: return nil
        }
    }

    /// HID++ `0x1b04` control IDs that can carry this button, in preference order.
    public var controlIDs: [UInt16] {
        switch self {
        case .wheelTiltLeft: return [ControlID.tiltLeft]
        case .wheelTiltRight: return [ControlID.tiltRight]
        case .modeShift: return ControlID.modeShift
        case .gestureButton: return ControlID.gesture
        case .hapticPanel: return [ControlID.hapticPanel]
        default: return []
        }
    }

    /// Wheel rotations, which fire repeatedly rather than press/release.
    public var isRotation: Bool {
        switch self {
        case .wheelUp, .wheelDown, .thumbwheelUp, .thumbwheelDown: return true
        default: return false
        }
    }

    /// Whether "hold and move the mouse" gestures can be assigned.
    /// HID++ sources use raw-XY diversion; tap sources track cursor motion.
    public var supportsGestures: Bool {
        switch self {
        case .gestureButton, .modeShift, .hapticPanel, .middleClick, .back, .forward: return true
        default: return false
        }
    }

    /// Controls shown on the Buttons page (rotations live on the Scrolling page).
    public static let buttonPageControls: [ButtonID] = [
        .middleClick, .wheelTiltLeft, .wheelTiltRight, .modeShift,
        .gestureButton, .hapticPanel, .back, .forward,
    ]
}

public enum GestureDirection: String, CaseIterable, Codable, CodingKeyRepresentable, Hashable, Sendable {
    case click, up, down, left, right

    public var label: String {
        switch self {
        case .click: return "Click"
        case .up: return "Hold + move up"
        case .down: return "Hold + move down"
        case .left: return "Hold + move left"
        case .right: return "Hold + move right"
        }
    }

    public var symbol: String {
        switch self {
        case .click: return "circle.circle"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }
}
