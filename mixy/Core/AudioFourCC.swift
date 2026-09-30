import Foundation

/// Four-character code helpers used for HAL transport types and inventory output.
public enum AudioFourCC: Sendable {
    public static func string(from value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        if bytes.allSatisfy({ isprint(Int32($0)) != 0 }) {
            return String(bytes.map { Character(UnicodeScalar($0)) })
        }
        return String(format: "0x%08x", value)
    }

    public static func value(from string: String) -> UInt32? {
        let scalars = Array(string.utf8)
        guard scalars.count == 4 else { return nil }
        return (UInt32(scalars[0]) << 24)
            | (UInt32(scalars[1]) << 16)
            | (UInt32(scalars[2]) << 8)
            | UInt32(scalars[3])
    }
}
