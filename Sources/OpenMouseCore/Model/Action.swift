import Foundation

public enum MouseButton: String, Codable, CaseIterable, Hashable, Sendable {
    case left, right, middle, back, forward

    /// `kCGMouseEventButtonNumber` value.
    public var buttonNumber: Int64 {
        switch self {
        case .left: return 0
        case .right: return 1
        case .middle: return 2
        case .back: return 3
        case .forward: return 4
        }
    }

    public var label: String {
        switch self {
        case .left: return "Left Click"
        case .right: return "Right Click"
        case .middle: return "Middle Click"
        case .back: return "Back (Mouse Button 4)"
        case .forward: return "Forward (Mouse Button 5)"
        }
    }
}

public enum ScrollDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case up, down, left, right

    public var label: String {
        switch self {
        case .up: return "Scroll Up"
        case .down: return "Scroll Down"
        case .left: return "Scroll Left"
        case .right: return "Scroll Right"
        }
    }
}

/// Built-in, parameterless actions. The raw value is the on-disk name and is frozen.
public enum StandardAction: String, Codable, CaseIterable, Hashable, Sendable {
    // Editing
    case copy, paste, cut, undo, redo, selectAll, find, save
    // Browser & tabs
    case browserBack, browserForward, newTab, closeTab, reopenTab, nextTab, previousTab, reload
    // Zoom
    case zoomIn, zoomOut, zoomReset
    // macOS
    case missionControl, appExpose, showDesktop, launchpad, previousDesktop, nextDesktop
    case appSwitcher, spotlight, notificationCenter
    case lockScreen, screenshot, captureRegion, screenshotToolbar, sleep
    // Media
    case playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute, brightnessUp, brightnessDown
    // Device
    case cycleDPI, toggleSmartShift

    public var label: String {
        switch self {
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .cut: return "Cut"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .selectAll: return "Select All"
        case .find: return "Find"
        case .save: return "Save"
        case .browserBack: return "Navigate Back (⌘[)"
        case .browserForward: return "Navigate Forward (⌘])"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .reopenTab: return "Reopen Closed Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .reload: return "Reload"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .zoomReset: return "Actual Size"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Show Desktop"
        case .launchpad: return "Launchpad / Apps"
        case .previousDesktop: return "Previous Desktop"
        case .nextDesktop: return "Next Desktop"
        case .appSwitcher: return "App Switcher (⌘⇥)"
        case .spotlight: return "Spotlight"
        case .notificationCenter: return "Notification Center"
        case .lockScreen: return "Lock Screen"
        case .screenshot: return "Screenshot"
        case .captureRegion: return "Capture Region to Clipboard"
        case .screenshotToolbar: return "Screenshot Toolbar"
        case .sleep: return "Sleep"
        case .playPause: return "Play / Pause"
        case .nextTrack: return "Next Track"
        case .previousTrack: return "Previous Track"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .brightnessUp: return "Brightness Up"
        case .brightnessDown: return "Brightness Down"
        case .cycleDPI: return "Cycle DPI Presets"
        case .toggleSmartShift: return "Toggle Ratchet / Free-spin"
        }
    }

    public var symbol: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .paste: return "doc.on.clipboard"
        case .cut: return "scissors"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        case .selectAll: return "selection.pin.in.out"
        case .find: return "magnifyingglass"
        case .save: return "square.and.arrow.down"
        case .browserBack: return "chevron.backward"
        case .browserForward: return "chevron.forward"
        case .newTab: return "plus.square.on.square"
        case .closeTab: return "xmark.square"
        case .reopenTab: return "arrow.counterclockwise.square"
        case .nextTab: return "arrow.right.square"
        case .previousTab: return "arrow.left.square"
        case .reload: return "arrow.clockwise"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .zoomReset: return "1.magnifyingglass"
        case .missionControl: return "rectangle.3.group"
        case .appExpose: return "rectangle.stack"
        case .showDesktop: return "menubar.dock.rectangle"
        case .launchpad: return "square.grid.3x3"
        case .previousDesktop: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .nextDesktop: return "rectangle.righthalf.inset.filled.arrow.right"
        case .appSwitcher: return "square.on.square"
        case .spotlight: return "magnifyingglass.circle"
        case .notificationCenter: return "bell"
        case .lockScreen: return "lock"
        case .screenshot: return "camera.viewfinder"
        case .captureRegion: return "crop"
        case .screenshotToolbar: return "camera.on.rectangle"
        case .sleep: return "moon"
        case .playPause: return "playpause"
        case .nextTrack: return "forward"
        case .previousTrack: return "backward"
        case .volumeUp: return "speaker.wave.3"
        case .volumeDown: return "speaker.wave.1"
        case .mute: return "speaker.slash"
        case .brightnessUp: return "sun.max"
        case .brightnessDown: return "sun.min"
        case .cycleDPI: return "gauge.with.dots.needle.67percent"
        case .toggleSmartShift: return "gearshape.2"
        }
    }

    /// Fixed keyboard shortcut for actions that are just a chord.
    public var shortcut: KeyCombo? {
        typealias M = KeyCombo.Modifiers
        func k(_ code: UInt16, _ m: M, _ label: String) -> KeyCombo { KeyCombo(keyCode: code, modifiers: m, keyLabel: label) }
        switch self {
        case .copy: return k(KeyCodes.c, .command, "C")
        case .paste: return k(KeyCodes.v, .command, "V")
        case .cut: return k(KeyCodes.x, .command, "X")
        case .undo: return k(KeyCodes.z, .command, "Z")
        case .redo: return k(KeyCodes.z, [.command, .shift], "Z")
        case .selectAll: return k(KeyCodes.a, .command, "A")
        case .find: return k(KeyCodes.f, .command, "F")
        case .save: return k(KeyCodes.s, .command, "S")
        case .browserBack: return k(KeyCodes.leftBracket, .command, "[")
        case .browserForward: return k(KeyCodes.rightBracket, .command, "]")
        case .newTab: return k(KeyCodes.t, .command, "T")
        case .closeTab: return k(KeyCodes.w, .command, "W")
        case .reopenTab: return k(KeyCodes.t, [.command, .shift], "T")
        case .nextTab: return k(KeyCodes.tab, .control, "⇥")
        case .previousTab: return k(KeyCodes.tab, [.control, .shift], "⇥")
        case .reload: return k(KeyCodes.r, .command, "R")
        case .zoomIn: return k(KeyCodes.equal, .command, "=")
        case .zoomOut: return k(KeyCodes.minus, .command, "-")
        case .zoomReset: return k(KeyCodes.zero, .command, "0")
        case .appSwitcher: return k(KeyCodes.tab, .command, "⇥")
        case .spotlight: return k(KeyCodes.space, .command, "Space")
        case .lockScreen: return k(KeyCodes.q, [.command, .control], "Q")
        default: return nil
        }
    }

    public var category: ActionCategory {
        switch self {
        case .copy, .paste, .cut, .undo, .redo, .selectAll, .find, .save: return .editing
        case .browserBack, .browserForward, .newTab, .closeTab, .reopenTab, .nextTab, .previousTab, .reload,
             .zoomIn, .zoomOut, .zoomReset: return .navigation
        case .missionControl, .appExpose, .showDesktop, .launchpad, .previousDesktop, .nextDesktop,
             .appSwitcher, .spotlight, .notificationCenter: return .windows
        case .lockScreen, .screenshot, .captureRegion, .screenshotToolbar, .sleep: return .system
        case .playPause, .nextTrack, .previousTrack, .volumeUp, .volumeDown, .mute, .brightnessUp, .brightnessDown: return .media
        case .cycleDPI, .toggleSmartShift: return .device
        }
    }
}

public enum ActionCategory: String, CaseIterable, Sendable {
    case mouse = "Mouse"
    case navigation = "Browser & Navigation"
    case editing = "Editing"
    case windows = "Desktop & Windows"
    case media = "Media"
    case system = "System"
    case device = "Mouse Settings"
    case advanced = "Advanced"
}

/// What a control does when triggered.
public enum Action: Codable, Hashable, Sendable {
    /// Leave the control alone: no interception, the device behaves natively.
    case systemDefault
    /// Swallow the input so it does nothing.
    case disabled
    case mouse(MouseButton)
    case standard(StandardAction)
    case scroll(ScrollDirection)
    case shortcut(KeyCombo)
    case setDPI(Int)
    case openApplication(path: String)
    case openURL(String)
    case shellCommand(String)
    case appleScript(String)
    case typeText(String)

    public var label: String {
        switch self {
        case .systemDefault: return "Default"
        case .disabled: return "Do Nothing"
        case let .mouse(b): return b.label
        case let .standard(s): return s.label
        case let .scroll(d): return d.label
        case let .shortcut(k): return "Shortcut \(k.display)"
        case let .setDPI(dpi): return "Set DPI to \(dpi)"
        case let .openApplication(path):
            let name = (path as NSString).lastPathComponent
            return "Open \(name.hasSuffix(".app") ? String(name.dropLast(4)) : name)"
        case let .openURL(url): return "Open \(url)"
        case .shellCommand: return "Run Shell Command"
        case .appleScript: return "Run AppleScript"
        case let .typeText(text): return "Type “\(text.prefix(20))\(text.count > 20 ? "…" : "")”"
        }
    }

    public var symbol: String {
        switch self {
        case .systemDefault: return "arrow.uturn.backward.circle"
        case .disabled: return "nosign"
        case .mouse: return "computermouse"
        case let .standard(s): return s.symbol
        case let .scroll(d):
            switch d {
            case .up: return "arrow.up"
            case .down: return "arrow.down"
            case .left: return "arrow.left"
            case .right: return "arrow.right"
            }
        case .shortcut: return "command"
        case .setDPI: return "gauge.with.dots.needle.50percent"
        case .openApplication: return "app"
        case .openURL: return "link"
        case .shellCommand: return "terminal"
        case .appleScript: return "applescript"
        case .typeText: return "text.cursor"
        }
    }

    /// Whether this action needs the control intercepted at all.
    public var intercepts: Bool { self != .systemDefault }

    /// The catalog shown in the action picker, grouped by category.
    public static let catalog: [(ActionCategory, [Action])] = {
        var groups: [(ActionCategory, [Action])] = [
            (.mouse, MouseButton.allCases.map { .mouse($0) } + ScrollDirection.allCases.map { .scroll($0) }),
        ]
        for category in ActionCategory.allCases where category != .mouse && category != .advanced {
            let actions = StandardAction.allCases.filter { $0.category == category }.map { Action.standard($0) }
            if !actions.isEmpty { groups.append((category, actions)) }
        }
        return groups
    }()
}

// MARK: - Bindings

/// Per-direction actions for a control in gesture mode.
public struct GestureActions: Codable, Hashable, Sendable {
    public var click: Action
    public var up: Action
    public var down: Action
    public var left: Action
    public var right: Action

    public init(click: Action = .disabled, up: Action = .disabled, down: Action = .disabled, left: Action = .disabled, right: Action = .disabled) {
        self.click = click
        self.up = up
        self.down = down
        self.left = left
        self.right = right
    }

    public subscript(direction: GestureDirection) -> Action {
        get {
            switch direction {
            case .click: return click
            case .up: return up
            case .down: return down
            case .left: return left
            case .right: return right
            }
        }
        set {
            switch direction {
            case .click: click = newValue
            case .up: up = newValue
            case .down: down = newValue
            case .left: left = newValue
            case .right: right = newValue
            }
        }
    }

    /// Options+-style default for the gesture button.
    public static let desktopNavigation = GestureActions(
        click: .standard(.missionControl),
        up: .standard(.missionControl),
        down: .standard(.appExpose),
        left: .standard(.previousDesktop),
        right: .standard(.nextDesktop)
    )
}

public enum ButtonBinding: Codable, Hashable, Sendable {
    case single(Action)
    case gestures(GestureActions)

    public var intercepts: Bool {
        switch self {
        case let .single(action): return action.intercepts
        case .gestures: return true
        }
    }

    public var isGesture: Bool {
        if case .gestures = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case let .single(action): return action.label
        case .gestures: return "Gestures"
        }
    }

    public static let `default` = ButtonBinding.single(.systemDefault)
}
