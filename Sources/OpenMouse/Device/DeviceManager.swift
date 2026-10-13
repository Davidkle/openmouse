import Foundation
import IOKit.hid
import Observation
import OpenMouseCore

/// Finds Logitech HID++ interfaces, probes receivers for paired devices, and
/// keeps the list of connected mice.
@MainActor
@Observable
final class DeviceManager {
    private(set) var devices: [LogiDevice] = []
    private(set) var receivers: [String] = []
    /// Whether macOS lets us open HID devices (Input Monitoring). Bluetooth
    /// mice often expose a keyboard collection that requires it.
    private(set) var inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    /// Interfaces we matched but couldn't open yet.
    @ObservationIgnored private var unopened: [IOHIDDevice] = []
    @ObservationIgnored private var accessTimer: Timer?

    /// Called whenever a device finishes setup and needs bindings applied.
    @ObservationIgnored var onDeviceReady: ((LogiDevice) -> Void)?
    @ObservationIgnored weak var delegate: LogiDeviceDelegate?

    @ObservationIgnored private var manager: IOHIDManager?
    @ObservationIgnored private var transports: [UInt64: HIDTransport] = [:]

    /// HID++ long-report collections, as (usage page, usage):
    /// 0xFF00/0x0002 for USB and receivers,
    /// 0xFF43/0x0202 for Bluetooth LE (long reports only).
    private static let collections: [(page: Int, usage: Int, longOnly: Bool)] = [
        (0xFF00, 0x0002, false),
        (0xFF43, 0x0202, true),
        (0xFF43, 0x0602, false),
    ]

    var pointerDevices: [LogiDevice] {
        devices.filter { $0.kind.isPointer || $0.kind == .unknown }
    }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = Self.collections.map { c -> [String: Any] in
            [kIOHIDVendorIDKey: 0x046D, kIOHIDDeviceUsagePageKey: c.page, kIOHIDDeviceUsageKey: c.usage]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<DeviceManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.added(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let me = Unmanaged<DeviceManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.removed(device) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    func requestInputMonitoring() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        pollAccess()
    }

    /// Retry interfaces that failed to open, e.g. once access is granted.
    private func retryUnopened() {
        let pending = unopened
        unopened.removeAll()
        pending.forEach(added)
    }

    private func pollAccess() {
        guard accessTimer == nil else { return }
        accessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
                if self.inputMonitoringGranted {
                    timer.invalidate()
                    self.accessTimer = nil
                    self.retryUnopened()
                }
            }
        }
    }

    func stop() async {
        for device in devices where device.connected {
            await device.releaseAll()
        }
        transports.values.forEach { $0.close() }
        transports.removeAll()
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    /// Re-run discovery on every interface (e.g. after wake from sleep).
    func rescan() {
        retryUnopened()
        for transport in transports.values {
            Task { await probe(transport) }
        }
    }

    // MARK: Hotplug

    private func longOnly(_ device: IOHIDDevice) -> Bool {
        let pairs = (IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Int]]) ?? []
        let usages = pairs.map { ($0[kIOHIDDeviceUsagePageKey] ?? 0, $0[kIOHIDDeviceUsageKey] ?? 0) }
        return Self.collections.contains { c in c.longOnly && usages.contains { $0 == (c.page, c.usage) } }
            && !usages.contains { $0 == (0xFF00, 0x0001) || $0 == (0xFF43, 0x0201) }
    }

    private func added(_ device: IOHIDDevice) {
        let transport = HIDTransport(device: device, longOnly: longOnly(device))
        guard transports[transport.registryID] == nil else { return }
        guard transport.open() else {
            if !unopened.contains(where: { $0 === device }) { unopened.append(device) }
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
                inputMonitoringGranted = false
                requestInputMonitoring()
            }
            return
        }
        transports[transport.registryID] = transport
        transport.onNotification = { [weak self, weak transport] message in
            guard let self, let transport else { return }
            self.notification(message, from: transport)
        }
        hidLog.info("HID++ interface added: \(transport.productName, privacy: .public) (\(transport.transportKind, privacy: .public))")
        Task { await probe(transport) }
    }

    private func removed(_ device: IOHIDDevice) {
        // The service may already be gone, so match on the device object.
        unopened.removeAll { $0 === device }
        guard let entry = transports.first(where: { $0.value.device === device }) else { return }
        let transport = entry.value
        transports[entry.key] = nil
        transport.close()
        devices.removeAll { $0.transport === transport }
        receivers.removeAll { $0 == transport.productName }
    }

    // MARK: Probing

    private func probe(_ transport: HIDTransport) async {
        do {
            _ = try await transport.call(device: HIDPP.directDeviceIndex, feature: 0, function: 1, params: [0, 0, 0x5A], timeout: 1.5)
            // A HID++ 2.0 device answered directly: Bluetooth or wired.
            await attach(transport: transport, index: HIDPP.directDeviceIndex)
        } catch let HIDPPError.hidpp10(code) where code == 0x01 || transport.productName.localizedCaseInsensitiveContains("receiver") {
            // HID++ 1.0 "invalid sub-ID" from index 0xFF: this is a receiver.
            if !receivers.contains(transport.productName) { receivers.append(transport.productName) }
            await enableReceiverNotifications(transport)
            for index in UInt8(1)...6 {
                await attach(transport: transport, index: index, quiet: true, probeTimeout: 0.6)
            }
        } catch {
            hidLog.error("Probe failed for \(transport.productName, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func enableReceiverNotifications(_ transport: HIDTransport) async {
        // Register 0x00 (notification flags): OR in wireless + software-present,
        // keeping whatever other flags are set.
        let read = HIDPPMessage(deviceIndex: 0xFF, featureIndex: 0x81, functionByte: 0x00, payload: [0, 0, 0])
        var flags: [UInt8] = [0, 0, 0]
        if let reply = try? await transport.send(read, preferShort: true, timeout: 1) {
            flags = Array(reply.extendedPayload.prefix(3))
        }
        flags[1] |= 0x09
        let write = HIDPPMessage(deviceIndex: 0xFF, featureIndex: 0x80, functionByte: 0x00, payload: flags)
        _ = try? await transport.send(write, preferShort: true, timeout: 1)
    }

    private func attach(transport: HIDTransport, index: UInt8, quiet: Bool = false, probeTimeout: TimeInterval = 1.5) async {
        let id = "\(transport.registryID)-\(index)"
        let existing = devices.first { $0.id == id }
        let device = existing ?? LogiDevice(transport: transport, index: index, name: transport.productName)
        device.delegate = delegate
        do {
            if let existing, existing.isDiscovered {
                // Known device waking up: skip discovery, just re-arm it.
                try await existing.reconnect()
            } else {
                try await device.setup(probeTimeout: probeTimeout)
            }
        } catch {
            if !quiet {
                hidLog.error("Setup failed for \(device.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            device.markDisconnected()
            return
        }
        guard device.kind.isPointer || device.kind == .unknown else { return }
        if !devices.contains(where: { $0 === device }) {
            devices.append(device)
            devices.sort { $0.name < $1.name }
        }
        hidLog.info("Device ready: \(device.name, privacy: .public) HID++ \(device.protocolVersion, privacy: .public), \(device.controls.count) controls")
        onDeviceReady?(device)
    }

    private func notification(_ message: HIDPPMessage, from transport: HIDTransport) {
        // Receiver "device connection" notification (HID++ 1.0, sub-ID 0x41).
        if message.featureIndex == 0x41, (1...6).contains(message.deviceIndex) {
            let linkEstablished = message.payload.first.map { $0 & 0x40 == 0 } ?? false
            let id = "\(transport.registryID)-\(message.deviceIndex)"
            if linkEstablished {
                Task { await attach(transport: transport, index: message.deviceIndex) }
            } else {
                devices.first { $0.id == id }?.markDisconnected()
            }
            return
        }
        for device in devices where device.transport === transport && device.index == message.deviceIndex {
            device.handle(message)
        }
    }
}
