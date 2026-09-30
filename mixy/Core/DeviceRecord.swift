import CoreAudio
import Foundation

/// Kind derived from HAL transport metadata and channel layout — never guessed from UI state.
public enum DeviceKind: String, Codable, Sendable, Equatable {
    case airPlay
    case musicInterface
    case local
    case virtual
}

/// Snapshot of a HAL device used by classification, policy, inventory, and the mixer UI.
public struct DeviceRecord: Identifiable, Equatable, Sendable, Codable {
    public var uid: String
    public var name: String
    public var manufacturer: String
    public var transportType: UInt32
    public var inputChannelCount: Int
    public var outputChannelCount: Int
    public var sampleRate: Double

    public var id: String { uid }
    public var isInput: Bool { inputChannelCount > 0 }
    public var isOutput: Bool { outputChannelCount > 0 }

    public var transportFourCC: String { AudioFourCC.string(from: transportType) }

    public var transportName: String {
        AudioTransport.name(for: transportType)
    }

    public var kind: DeviceKind {
        DeviceClassifier.classify(self)
    }

    public var isAirPlay: Bool {
        DeviceClassifier.isAirPlay(self)
    }

    public init(
        uid: String,
        name: String,
        manufacturer: String = "",
        transportType: UInt32,
        inputChannelCount: Int,
        outputChannelCount: Int,
        sampleRate: Double = 48_000
    ) {
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.transportType = transportType
        self.inputChannelCount = inputChannelCount
        self.outputChannelCount = outputChannelCount
        self.sampleRate = sampleRate
    }
}

public enum AudioTransport: Sendable {
    public static func name(for type: UInt32) -> String {
        switch type {
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "Continuity Capture (Wired)"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity Capture (Wireless)"
        case kAudioDeviceTransportTypeRemoteScreen: return "Remote Screen"
        case kAudioDeviceTransportTypeRemoteStreaming: return "Remote Streaming"
        case kAudioDeviceTransportTypeUnknown: return "Unknown"
        default: return AudioFourCC.string(from: type)
        }
    }

    public static func isAirPlay(_ type: UInt32) -> Bool {
        type == kAudioDeviceTransportTypeAirPlay
    }

    public static func isVirtual(_ type: UInt32) -> Bool {
        type == kAudioDeviceTransportTypeVirtual
    }

    /// Local clock-capable hardware transports (not AirPlay, not remote streaming).
    public static func isLocalHardware(_ type: UInt32) -> Bool {
        switch type {
        case kAudioDeviceTransportTypeBuiltIn,
             kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeAVB,
             kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeAggregate:
            return true
        default:
            return false
        }
    }

    public static func isMusicInterfaceTransport(_ type: UInt32) -> Bool {
        switch type {
        case kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeAVB:
            return true
        default:
            return false
        }
    }
}
