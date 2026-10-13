import Foundation
import IOKit.hid
import OpenMouseCore
import os

let hidLog = Logger(subsystem: "dev.openmouse", category: "hid")

/// One HID++ capable IOHIDDevice interface: a Bolt / Unifying receiver, or a
/// mouse connected directly over Bluetooth or USB. Requests are serialized
/// (one in flight per interface), and replies are matched to requests by
/// `(device index, feature index, function | software id)`.
@MainActor
final class HIDTransport {
    let device: IOHIDDevice
    let registryID: UInt64
    let productName: String
    let productID: Int
    let transportKind: String
    /// Bluetooth LE devices only expose the long-report collection.
    let longOnly: Bool

    /// Unsolicited messages (software ID 0), e.g. diverted button events.
    var onNotification: ((HIDPPMessage) -> Void)?

    private let reportBuffer: UnsafeMutablePointer<UInt8>
    private static let bufferSize = 64
    private var closed = false

    private struct Key: Hashable { let device: UInt8, feature: UInt8, function: UInt8 }
    private struct Pending { let token: UInt64; let continuation: CheckedContinuation<HIDPPMessage, Error> }
    private var pending: [Key: Pending] = [:]
    private var nextToken: UInt64 = 0

    /// Rotates 1...15 so a late reply to a timed-out request can't be
    /// mistaken for the reply to the next identical-looking request.
    private var softwareIDCounter: UInt8 = 0

    private func nextSoftwareID() -> UInt8 {
        softwareIDCounter = softwareIDCounter % 15 + 1
        return softwareIDCounter
    }

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(device: IOHIDDevice, longOnly: Bool) {
        self.device = device
        self.longOnly = longOnly
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entryID)
        registryID = entryID
        productName = HIDTransport.property(device, kIOHIDProductKey) ?? "Logitech device"
        productID = HIDTransport.property(device, kIOHIDProductIDKey) ?? 0
        transportKind = HIDTransport.property(device, kIOHIDTransportKey) ?? "?"
        reportBuffer = .allocate(capacity: HIDTransport.bufferSize)
        reportBuffer.initialize(repeating: 0, count: HIDTransport.bufferSize)
    }

    deinit {
        reportBuffer.deallocate()
    }

    static func property<T>(_ device: IOHIDDevice, _ key: String) -> T? {
        IOHIDDeviceGetProperty(device, key as CFString) as? T
    }

    func open() -> Bool {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            hidLog.error("IOHIDDeviceOpen failed for \(self.productName, privacy: .public): \(String(format: "0x%08x", result), privacy: .public)")
            return false
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, HIDTransport.bufferSize, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let transport = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            // IOKit includes the report ID as the first byte for numbered
            // reports; be defensive in case a driver strips it.
            if let first = bytes.first, first != UInt8(truncatingIfNeeded: reportID), reportID != 0 {
                bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0)
            }
            MainActor.assumeIsolated { transport.received(bytes) }
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        return true
    }

    func close() {
        guard !closed else { return }
        closed = true
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, HIDTransport.bufferSize, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        for (_, p) in pending { p.continuation.resume(throwing: HIDPPError.disconnected) }
        pending.removeAll()
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.resume() }
    }

    // MARK: Requests

    /// HID++ 2.0 feature call. Like Solaar, uses a short report when the
    /// parameters fit (devices reply with whichever length they need).
    func call(device index: UInt8, feature: UInt8, function: UInt8, params: [UInt8] = [], timeout: TimeInterval = 2) async throws -> [UInt8] {
        let message = HIDPPMessage(deviceIndex: index, featureIndex: feature, function: function, softwareID: nextSoftwareID(), payload: params)
        return try await send(message, preferShort: true, timeout: timeout).extendedPayload
    }

    /// Send a message and wait for its reply.
    func send(_ message: HIDPPMessage, preferShort: Bool, timeout: TimeInterval) async throws -> HIDPPMessage {
        await acquire()
        defer { release() }
        guard !closed else { throw HIDPPError.disconnected }

        let report: [UInt8]
        if preferShort, !longOnly, let short = message.shortReport() {
            report = short
        } else {
            report = message.longReport()
        }
        let key = Key(device: message.deviceIndex, feature: message.featureIndex, function: message.functionByte)
        nextToken += 1
        let token = nextToken

        return try await withCheckedThrowingContinuation { continuation in
            pending[key] = Pending(token: token, continuation: continuation)
            let result = report.withUnsafeBufferPointer { buf in
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]), buf.baseAddress!, buf.count)
            }
            if result != kIOReturnSuccess {
                pending[key] = nil
                continuation.resume(throwing: HIDPPError.writeFailed(result))
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, let p = self.pending[key], p.token == token else { return }
                self.pending[key] = nil
                p.continuation.resume(throwing: HIDPPError.timeout)
            }
        }
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // MARK: Input

    private func received(_ bytes: [UInt8]) {
        guard let packet = HIDPPPacket(report: bytes) else { return }
        switch packet {
        case let .error(device, feature, function, code, hidpp20):
            let key = Key(device: device, feature: feature, function: function)
            if let p = pending.removeValue(forKey: key) {
                p.continuation.resume(throwing: hidpp20 ? HIDPPError.hidpp20(code: code) : HIDPPError.hidpp10(code: code))
            }
        case let .message(message):
            let key = Key(device: message.deviceIndex, feature: message.featureIndex, function: message.functionByte)
            if let p = pending.removeValue(forKey: key) {
                p.continuation.resume(returning: message)
            } else if message.softwareID == 0 || message.featureIndex >= 0x40 {
                onNotification?(message)
            }
        }
    }
}
