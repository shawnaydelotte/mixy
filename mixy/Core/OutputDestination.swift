import CoreAudio
import Foundation

/// Where an output was discovered.
public enum OutputDiscoverySource: String, Codable, Sendable, Equatable {
    case hal
    case sessionAirPlay
}

/// An AirPlay endpoint visible to the current macOS session (Bonjour / route
/// discovery) that may not yet exist as a HAL audio device.
public struct SessionAirPlayEndpoint: Equatable, Sendable, Codable, Identifiable {
    public var uid: String
    public var name: String
    /// `_airplay._tcp` carries video; `_raop._tcp` is audio-only.
    public var supportsVideo: Bool
    public var serviceType: String

    public var id: String { uid }
    public var supportsAudio: Bool { true }

    public init(uid: String, name: String, supportsVideo: Bool, serviceType: String) {
        self.uid = uid
        self.name = name
        self.supportsVideo = supportsVideo
        self.serviceType = serviceType
    }

    public static func uid(serviceType: String, name: String) -> String {
        "airplay:\(serviceType):\(name)"
    }
}

/// One selectable output: HAL device and/or session AirPlay destination.
public struct OutputDestination: Equatable, Sendable, Codable, Identifiable {
    public var uid: String
    public var name: String
    public var source: OutputDiscoverySource
    public var transportType: UInt32
    public var supportsAudio: Bool
    public var supportsVideo: Bool
    public var outputChannelCount: Int

    public var id: String { uid }

    public var isAirPlay: Bool {
        source == .sessionAirPlay || AudioTransport.isAirPlay(transportType)
    }

    public var kindLabel: String {
        isAirPlay ? "AirPlay" : AudioTransport.name(for: transportType)
    }

    public init(
        uid: String,
        name: String,
        source: OutputDiscoverySource,
        transportType: UInt32,
        supportsAudio: Bool,
        supportsVideo: Bool,
        outputChannelCount: Int
    ) {
        self.uid = uid
        self.name = name
        self.source = source
        self.transportType = transportType
        self.supportsAudio = supportsAudio
        self.supportsVideo = supportsVideo
        self.outputChannelCount = outputChannelCount
    }

    public init(hal device: DeviceRecord) {
        self.init(
            uid: device.uid,
            name: device.name,
            source: .hal,
            transportType: device.transportType,
            supportsAudio: device.isOutput,
            supportsVideo: Self.halSupportsVideo(device),
            outputChannelCount: max(device.outputChannelCount, 0)
        )
    }

    public init(session endpoint: SessionAirPlayEndpoint) {
        self.init(
            uid: endpoint.uid,
            name: endpoint.name,
            source: .sessionAirPlay,
            transportType: kAudioDeviceTransportTypeAirPlay,
            supportsAudio: endpoint.supportsAudio,
            supportsVideo: endpoint.supportsVideo,
            outputChannelCount: 2
        )
    }

    /// Device record used by AirPlayPolicy / the I/O graph.
    public var asDeviceRecord: DeviceRecord {
        DeviceRecord(
            uid: uid,
            name: name,
            manufacturer: isAirPlay ? "AirPlay" : "",
            transportType: transportType,
            inputChannelCount: 0,
            outputChannelCount: max(outputChannelCount, 2)
        )
    }

    public static func halSupportsVideo(_ device: DeviceRecord) -> Bool {
        if AudioTransport.isAirPlay(device.transportType) { return true }
        switch device.transportType {
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return true
        default:
            return false
        }
    }
}
