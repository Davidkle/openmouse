import Foundation

/// Logitech HID++ framing.
///
/// Short report: `[0x10, device, feature, fn<<4 | sw, p0, p1, p2]` (7 bytes)
/// Long report:  `[0x11, device, feature, fn<<4 | sw, p0 ... p15]` (20 bytes)
public enum HIDPP {
    public static let shortReportID: UInt8 = 0x10
    public static let longReportID: UInt8 = 0x11
    public static let shortReportLength = 7
    public static let longReportLength = 20

    /// Device index used for directly connected (USB / Bluetooth) devices and
    /// for addressing a receiver itself.
    public static let directDeviceIndex: UInt8 = 0xFF

    /// Software ID stamped on every request so responses can be told apart
    /// from unsolicited notifications (which always carry software ID 0).
    public static let softwareID: UInt8 = 0x0B

    /// Feature index byte used by HID++ 2.0 error responses.
    public static let hidpp20ErrorIndex: UInt8 = 0xFF
    /// Sub-ID used by HID++ 1.0 error responses.
    public static let hidpp10ErrorSubID: UInt8 = 0x8F
}

/// One HID++ request, response or notification.
public struct HIDPPMessage: Equatable, Sendable, CustomStringConvertible {
    public var deviceIndex: UInt8
    /// Feature index (HID++ 2.0) or sub-ID (HID++ 1.0).
    public var featureIndex: UInt8
    /// Function ID (HID++ 2.0, high nibble of byte 3). For HID++ 1.0 this byte
    /// is the register address and is carried whole in `functionByte`.
    public var functionByte: UInt8
    public var payload: [UInt8]

    public init(deviceIndex: UInt8, featureIndex: UInt8, functionByte: UInt8, payload: [UInt8]) {
        self.deviceIndex = deviceIndex
        self.featureIndex = featureIndex
        self.functionByte = functionByte
        self.payload = payload
    }

    public init(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8, softwareID: UInt8, payload: [UInt8]) {
        self.init(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionByte: (function & 0x0F) << 4 | (softwareID & 0x0F),
            payload: payload
        )
    }

    public var function: UInt8 { functionByte >> 4 }
    public var softwareID: UInt8 { functionByte & 0x0F }

    /// Payload padded with zeros to 16 bytes so parsers can index freely.
    public var extendedPayload: [UInt8] {
        payload.count >= 16 ? Array(payload.prefix(16)) : payload + Array(repeating: 0, count: 16 - payload.count)
    }

    public func longReport() -> [UInt8] {
        [HIDPP.longReportID, deviceIndex, featureIndex, functionByte] + extendedPayload
    }

    /// Short form, or `nil` when the payload doesn't fit in 3 bytes.
    public func shortReport() -> [UInt8]? {
        let trimmed = payload.count > 3 ? payload[3...].allSatisfy { $0 == 0 } : true
        guard trimmed else { return nil }
        let p = Array(extendedPayload.prefix(3))
        return [HIDPP.shortReportID, deviceIndex, featureIndex, functionByte] + p
    }

    public var description: String {
        let hex = payload.map { String(format: "%02x", $0) }.joined(separator: " ")
        return String(format: "dev=%02x feat=%02x fn=%x sw=%x [", deviceIndex, featureIndex, function, softwareID) + hex + "]"
    }
}

/// A parsed input report.
public enum HIDPPPacket: Equatable, Sendable {
    case message(HIDPPMessage)
    /// An error reply. `featureIndex` / `functionByte` echo the failed request.
    case error(deviceIndex: UInt8, featureIndex: UInt8, functionByte: UInt8, code: UInt8, hidpp20: Bool)

    public init?(report: [UInt8]) {
        guard report.count >= HIDPP.shortReportLength else { return nil }
        let id = report[0]
        let expected: Int
        switch id {
        case HIDPP.shortReportID: expected = HIDPP.shortReportLength
        case HIDPP.longReportID: expected = HIDPP.longReportLength
        default: return nil
        }
        guard report.count >= expected else { return nil }
        let device = report[1]
        let sub = report[2]
        if id == HIDPP.longReportID, sub == HIDPP.hidpp20ErrorIndex {
            self = .error(deviceIndex: device, featureIndex: report[3], functionByte: report[4], code: report[5], hidpp20: true)
            return
        }
        if id == HIDPP.shortReportID, sub == HIDPP.hidpp10ErrorSubID {
            self = .error(deviceIndex: device, featureIndex: report[3], functionByte: report[4], code: report[5], hidpp20: false)
            return
        }
        self = .message(HIDPPMessage(
            deviceIndex: device,
            featureIndex: sub,
            functionByte: report[3],
            payload: Array(report[4..<expected])
        ))
    }
}

public enum HIDPPError: Error, Equatable, CustomStringConvertible {
    case timeout
    case hidpp20(code: UInt8)
    case hidpp10(code: UInt8)
    case featureNotSupported(UInt16)
    case writeFailed(Int32)
    case disconnected
    case malformedResponse

    public var description: String {
        switch self {
        case .timeout: return "request timed out"
        case let .hidpp20(code): return "HID++ 2.0 error \(HIDPPError.hidpp20Name(code)) (0x\(String(code, radix: 16)))"
        case let .hidpp10(code): return "HID++ 1.0 error 0x\(String(code, radix: 16))"
        case let .featureNotSupported(id): return "feature 0x\(String(format: "%04x", id)) not supported"
        case let .writeFailed(code): return "write failed (IOReturn 0x\(String(UInt32(bitPattern: code), radix: 16)))"
        case .disconnected: return "device disconnected"
        case .malformedResponse: return "malformed response"
        }
    }

    static func hidpp20Name(_ code: UInt8) -> String {
        switch code {
        case 0x01: return "Unknown"
        case 0x02: return "InvalidArgument"
        case 0x03: return "OutOfRange"
        case 0x04: return "HardwareError"
        case 0x05: return "LogitechInternal"
        case 0x06: return "InvalidFeatureIndex"
        case 0x07: return "InvalidFunctionId"
        case 0x08: return "Busy"
        case 0x09: return "Unsupported"
        default: return "Unknown"
        }
    }
}
