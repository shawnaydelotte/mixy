import Foundation

public struct AirPlayDestination: Equatable, Sendable, Codable {
    public var uid: String
    public var bufferFrameSize: Int
    public var extraLatencyFrames: Int

    public init(uid: String, bufferFrameSize: Int, extraLatencyFrames: Int) {
        self.uid = uid
        self.bufferFrameSize = bufferFrameSize
        self.extraLatencyFrames = extraLatencyFrames
    }
}

/// Clock/buffer grouping produced by AirPlay policy. AirPlay destinations never share
/// a local aggregate or sample clock with built-in / music-interface devices.
public struct MixGraph: Equatable, Sendable, Codable {
    public var localClockDeviceUIDs: [String]
    public var isolatedAirPlayUIDs: [String]
    public var bufferFramesLocal: Int
    public var bufferFramesAirPlay: Int
    public var extraLatencyFramesAirPlay: Int

    public var airPlayDestinations: [AirPlayDestination] {
        isolatedAirPlayUIDs.map {
            AirPlayDestination(
                uid: $0,
                bufferFrameSize: bufferFramesAirPlay,
                extraLatencyFrames: extraLatencyFramesAirPlay
            )
        }
    }

    public init(
        localClockDeviceUIDs: [String],
        isolatedAirPlayUIDs: [String],
        bufferFramesLocal: Int,
        bufferFramesAirPlay: Int,
        extraLatencyFramesAirPlay: Int
    ) {
        self.localClockDeviceUIDs = localClockDeviceUIDs
        self.isolatedAirPlayUIDs = isolatedAirPlayUIDs
        self.bufferFramesLocal = bufferFramesLocal
        self.bufferFramesAirPlay = bufferFramesAirPlay
        self.extraLatencyFramesAirPlay = extraLatencyFramesAirPlay
    }
}

public enum MixPolicyError: Error, Equatable, Sendable {
    case airPlayCannotJoinLocalClock(uid: String)
}

public enum AirPlayPolicy: Sendable {
    public static let localBufferFrames = 512
    public static let airPlayBufferFrames = 4096
    public static let airPlayExtraLatencyFrames = 4096

    public static func allowsSharedLocalClock(_ device: DeviceRecord) -> Bool {
        DeviceClassifier.classify(device) != .airPlay
    }

    /// Builds the I/O graph. AirPlay devices are isolated onto their own high-latency path.
    public static func buildGraph(devices: [DeviceRecord], enabledUIDs: Set<String>) -> MixGraph {
        var local: [String] = []
        var airPlay: [String] = []
        for device in devices where enabledUIDs.contains(device.uid) {
            if DeviceClassifier.isAirPlay(device) {
                airPlay.append(device.uid)
            } else {
                local.append(device.uid)
            }
        }
        return MixGraph(
            localClockDeviceUIDs: local,
            isolatedAirPlayUIDs: airPlay,
            bufferFramesLocal: localBufferFrames,
            bufferFramesAirPlay: airPlayBufferFrames,
            extraLatencyFramesAirPlay: airPlayExtraLatencyFrames
        )
    }

    /// Rebuild when the HAL device list changes (appear / disappear).
    public static func applyingDeviceChange(
        previous: MixGraph,
        devices: [DeviceRecord],
        enabledUIDs: Set<String>
    ) -> (graph: MixGraph, changed: Bool) {
        let next = buildGraph(devices: devices, enabledUIDs: enabledUIDs)
        return (next, next != previous)
    }

    /// UIDs that may be composed into a Core Audio aggregate. Rejects AirPlay.
    public static func localAggregateUIDs(including devices: [DeviceRecord]) throws -> [String] {
        var uids: [String] = []
        for device in devices {
            if DeviceClassifier.isAirPlay(device) {
                throw MixPolicyError.airPlayCannotJoinLocalClock(uid: device.uid)
            }
            uids.append(device.uid)
        }
        return uids
    }

    public static func ioConfiguration(
        devices: [DeviceRecord],
        enabledUIDs: Set<String>
    ) -> MixGraph {
        buildGraph(devices: devices, enabledUIDs: enabledUIDs)
    }
}
