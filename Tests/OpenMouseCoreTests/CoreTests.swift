import Foundation
import Testing
@testable import OpenMouseCore

@Suite struct HIDPPFramingTests {
    @Test func longReportRoundTrip() {
        let msg = HIDPPMessage(deviceIndex: 0x02, featureIndex: 0x07, function: 3, softwareID: HIDPP.softwareID, payload: [0x00, 0xC3, 0x03])
        let report = msg.longReport()
        #expect(report.count == HIDPP.longReportLength)
        #expect(Array(report.prefix(7)) == [0x11, 0x02, 0x07, 0x3B, 0x00, 0xC3, 0x03])
        #expect(HIDPPPacket(report: report) == .message(HIDPPMessage(deviceIndex: 2, featureIndex: 7, functionByte: 0x3B, payload: Array(report[4...]))))
    }

    @Test func shortReportOnlyWhenPayloadFits() {
        let fits = HIDPPMessage(deviceIndex: 0xFF, featureIndex: 0x00, function: 1, softwareID: 0xB, payload: [0, 0, 0x5A])
        #expect(fits.shortReport() == [0x10, 0xFF, 0x00, 0x1B, 0x00, 0x00, 0x5A])
        let tooLong = HIDPPMessage(deviceIndex: 1, featureIndex: 2, function: 0, softwareID: 0, payload: [1, 2, 3, 4])
        #expect(tooLong.shortReport() == nil)
    }

    @Test func parsesErrors() {
        var v20 = [UInt8](repeating: 0, count: 20)
        v20[0] = 0x11; v20[1] = 0xFF; v20[2] = 0xFF; v20[3] = 0x05; v20[4] = 0x1B; v20[5] = 0x02
        #expect(HIDPPPacket(report: v20) == .error(deviceIndex: 0xFF, featureIndex: 0x05, functionByte: 0x1B, code: 0x02, hidpp20: true))
        let v10: [UInt8] = [0x10, 0x03, 0x8F, 0x00, 0x1B, 0x09, 0x00]
        #expect(HIDPPPacket(report: v10) == .error(deviceIndex: 3, featureIndex: 0, functionByte: 0x1B, code: 9, hidpp20: false))
    }

    @Test func rejectsForeignReports() {
        #expect(HIDPPPacket(report: [0x02, 1, 2, 3, 4, 5, 6]) == nil)
        #expect(HIDPPPacket(report: [0x11, 1, 2]) == nil)
    }
}

@Suite struct FeaturePayloadTests {
    @Test func cidInfoFlags() {
        // CID 0x00C3, task 0x009C, flags: mouse|reprog|divertable|persist (0x71), rawXY in byte 8.
        let info = CIDInfo(payload: [0x00, 0xC3, 0x00, 0x9C, 0x71, 0x07, 0x03, 0x00, 0x01])
        #expect(info.cid == 0x00C3)
        #expect(info.taskID == 0x009C)
        #expect(info.isDivertable)
        #expect(info.supportsRawXY)
        #expect(info.position == 7)
    }

    @Test func reportingChangeEncoding() {
        let p = CIDReportingChange(diverted: true, rawXY: true).payload(cid: 0x00C3)
        #expect(Array(p.prefix(5)) == [0x00, 0xC3, 0b0011_0011, 0, 0])
        let undivert = CIDReportingChange(diverted: false, rawXY: false).payload(cid: 0x00C4)
        #expect(undivert[2] == 0b0010_0010)
    }

    @Test func divertedButtonsAndRawXY() {
        #expect(ReprogControlsEvent(function: 0, payload: [0x00, 0xC3, 0x00, 0xC4]) == .divertedButtons([0xC3, 0xC4]))
        #expect(ReprogControlsEvent(function: 0, payload: []) == .divertedButtons([]))
        #expect(ReprogControlsEvent(function: 1, payload: [0xFF, 0xFB, 0x00, 0x0C]) == .rawXY(dx: -5, dy: 12))
        #expect(ReprogControlsEvent(function: 2, payload: []) == nil)
    }

    @Test func dpiLists() {
        #expect(DPIList.parse([0x01, 0x90, 0x03, 0x20, 0x06, 0x40, 0x00, 0x00]) == [400, 800, 1600])
        #expect(DPIList.parse([0x01, 0x90, 0xE1, 0x90, 0x06, 0x40, 0x00, 0x00]) == [400, 800, 1200, 1600])
        #expect(DPIList.parse([0x06, 0x40, 0x03, 0x20, 0x03, 0x20, 0x00]) == [800, 1600])
        #expect(DPIList.parse([0xE0, 0x32, 0x1F, 0x40]) == [])
    }

    @Test func thumbwheel() {
        let info = ThumbwheelInfo(payload: [0x00, 0x12, 0x00, 0x78, 0x01, 0x0F])
        #expect(info.nativeResolution == 18)
        #expect(info.divertedResolution == 120)
        #expect(info.positiveIsRightOrFront)
        #expect(info.supportsSingleTap)
        let rolling = ThumbwheelEvent(payload: [0xFF, 0xFE, 0, 0, 2, 0x08])
        #expect(rolling.rotation == -2)
        #expect(rolling.singleTap)
        #expect(!rolling.isTap)
        let stop = ThumbwheelEvent(payload: [0, 0, 0, 0, 3, 0x08])
        #expect(!stop.isTap)
        let tap = ThumbwheelEvent(payload: [0, 0, 0, 0, 0, 0x08])
        #expect(tap.isTap)
    }

    @Test func battery() {
        #expect(BatteryStatus.unified([55, 0x04, 1]) == BatteryStatus(percent: 55, state: .charging))
        #expect(BatteryStatus.unified([0, 0x02, 0]) == BatteryStatus(percent: 20, state: .discharging))
        #expect(BatteryStatus.legacy([90, 50, 3]) == BatteryStatus(percent: 90, state: .full))
    }

    @Test func smartShiftSettingsToWire() {
        var s = SmartShiftSettings()
        s.sensitivity = 30
        #expect(s.hidppStatus == SmartShiftStatus(mode: .ratchet, autoDisengage: 30))
        s.enabled = false
        s.fixedMode = .freespin
        #expect(s.hidppStatus == SmartShiftStatus(mode: .freespin, autoDisengage: 0xFF))
    }
}

@Suite struct SwipeTests {
    @Test func thresholdsAndDiagonals() {
        #expect(Swipe.detect(dx: 40, dy: 5) == nil)
        #expect(Swipe.detect(dx: 120, dy: 5) == .right)
        #expect(Swipe.detect(dx: -120, dy: 5) == .left)
        #expect(Swipe.detect(dx: 5, dy: 120) == .down)
        #expect(Swipe.detect(dx: 5, dy: -120) == .up)
        #expect(Swipe.detect(dx: 60, dy: 60) == nil)
        #expect(Swipe.detect(dx: 200, dy: 69) == .right)
        #expect(Swipe.detect(dx: 200, dy: 71) == nil)
        #expect(Swipe.detect(dx: Int.min, dy: 0) == .left)
        #expect(Swipe.detect(dx: Int.max, dy: 0) == .right)
    }

    @Test func accumulatorRespectsHoldGate() {
        var acc = SwipeAccumulator()
        let t0 = Date()
        acc.begin(at: t0)
        #expect(acc.accumulate(dx: 100, dy: 0, now: t0.addingTimeInterval(0.05)) == nil)
        #expect(acc.accumulate(dx: 10, dy: 0, now: t0.addingTimeInterval(0.2)) == .right)
        #expect(acc.accumulate(dx: 500, dy: 0, now: t0.addingTimeInterval(0.3)) == nil)
        let wasClick = acc.end()
        #expect(!wasClick)
    }

    @Test func clickWhenNoSwipe() {
        var acc = SwipeAccumulator()
        acc.begin()
        _ = acc.accumulate(dx: 3, dy: -2)
        let first = acc.end()
        let second = acc.end()
        #expect(first)
        #expect(!second)
    }
}

@Suite struct ConfigTests {
    @Test func roundTripsAllActionKinds() throws {
        var config = Config()
        config.bindings[.middleClick] = .single(.shortcut(KeyCombo(keyCode: KeyCodes.c, modifiers: [.command, .shift])))
        config.bindings[.back] = .single(.openApplication(path: "/Applications/Safari.app"))
        config.bindings[.forward] = .single(.mouse(.middle))
        config.bindings[.thumbwheelUp] = .single(.standard(.volumeUp))
        config.bindings[.modeShift] = .gestures(GestureActions(click: .standard(.cycleDPI), up: .setDPI(1600)))
        config.appProfiles = [AppProfile(bundleID: "com.apple.Safari", name: "Safari", bindings: [.back: .single(.standard(.browserBack))])]
        config.devices["MX Master 3S"] = DeviceSettings(dpi: 1600, smartShift: SmartShiftSettings())
        let decoded = try Config.decode(try config.encoded())
        #expect(decoded == config)
        let json = String(decoding: try config.encoded(), as: UTF8.self)
        #expect(json.contains("\"middleClick\""))
    }

    @Test func toleratesMissingFields() throws {
        let decoded = try Config.decode(Data("{\"scroll\":{\"invertVertical\":true}}".utf8))
        #expect(decoded.scroll.invertVertical)
        #expect(decoded.scroll.verticalSpeed == 1)
        #expect(decoded.bindings == Config.defaultBindings)
    }

    @Test func appProfilesOverrideGlobals() {
        var config = Config()
        config.bindings[.back] = .single(.standard(.copy))
        config.appProfiles = [AppProfile(bundleID: "com.example", name: "Example", bindings: [.back: .single(.standard(.paste))])]
        #expect(config.binding(for: .back, app: nil) == .single(.standard(.copy)))
        #expect(config.binding(for: .back, app: "com.other") == .single(.standard(.copy)))
        #expect(config.binding(for: .back, app: "com.example") == .single(.standard(.paste)))
        #expect(config.binding(for: .forward, app: "com.example") == .default)
    }
}

@Suite struct CapturePlanTests {
    let controls = [
        CIDInfo(cid: 0x0052, taskID: 0x38, flags: [.mouse, .reprogrammable, .divertable]),
        CIDInfo(cid: 0x00C3, taskID: 0x9C, flags: [.mouse, .reprogrammable, .divertable, .rawXY]),
        CIDInfo(cid: 0x00C4, taskID: 0x9D, flags: [.mouse, .reprogrammable, .divertable, .rawXY]),
        CIDInfo(cid: 0x005B, taskID: 0x3E, flags: [.mouse]),
    ]

    @Test func divertsOnlyRemappedHIDPPControls() {
        var config = Config()
        config.bindings[.modeShift] = .single(.standard(.copy))
        config.bindings[.wheelTiltLeft] = .single(.standard(.copy)) // not divertable on this device
        config.bindings[.middleClick] = .single(.standard(.paste))  // event tap, never diverted
        let plan = CapturePlan.make(config: config, app: nil, controls: controls, hasThumbwheel: true)
        #expect(plan.diversions[0x00C3] == .init(button: .gestureButton, rawXY: true))
        #expect(plan.diversions[0x00C4] == .init(button: .modeShift, rawXY: false))
        #expect(plan.diversions[0x005B] == nil)
        #expect(plan.diversions[0x0052] == nil)
        #expect(plan.divertThumbwheel == false)
    }

    @Test func thumbwheelDivertsForSpeedOrBindings() {
        var config = Config(bindings: [:])
        config.scroll.invertThumbwheel = true
        var plan = CapturePlan.make(config: config, app: nil, controls: [], hasThumbwheel: true)
        #expect(!plan.divertThumbwheel)
        #expect(plan.invertThumbwheel)
        config.scroll.thumbwheelSpeed = 2
        plan = CapturePlan.make(config: config, app: nil, controls: [], hasThumbwheel: true)
        #expect(plan.divertThumbwheel)
        #expect(!plan.invertThumbwheel)
    }

    @Test func pausedDivertsNothing() {
        var config = Config()
        config.general.paused = true
        let plan = CapturePlan.make(config: config, app: nil, controls: controls, hasThumbwheel: true)
        #expect(plan == CapturePlan())
    }
}
