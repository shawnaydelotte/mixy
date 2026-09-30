import Foundation

public enum HALIORole: Sendable {
    case input
    case localOutput
    case airPlayOutput
}

/// One slice of the capture → mix → route cycle.
public struct IOCycleResult: Equatable, Sendable {
    public var mixed: PCMBuffer
    /// Immediate local-clock destinations (never delayed through AirPlaySafeBuffer).
    public var localOutputs: [String: PCMBuffer]
    /// Isolated AirPlay destinations pulled from AirPlaySafeBuffer only.
    public var airPlayOutputs: [String: PCMBuffer]

    public init(mixed: PCMBuffer, localOutputs: [String: PCMBuffer], airPlayOutputs: [String: PCMBuffer]) {
        self.mixed = mixed
        self.localOutputs = localOutputs
        self.airPlayOutputs = airPlayOutputs
    }
}

/// Shipped I/O cycle: captured inputs → ChannelMixer → local outputs;
/// AirPlay destinations are written/read only through AirPlaySafeBuffer.
public enum MixIOCycle: Sendable {
    public static func run(
        captures: [String: PCMBuffer],
        strips: [MixerStrip],
        devices: [DeviceRecord],
        graph: MixGraph,
        airPlayFeeds: inout [String: AirPlaySafeBuffer],
        frameCount: Int,
        mixChannelCount: Int
    ) -> IOCycleResult {
        let sources = Self.sources(from: captures, strips: strips, destinationChannelCount: mixChannelCount)
        let mixed = ChannelMixer.mix(
            sources: sources,
            outputChannelCount: mixChannelCount,
            frameCount: frameCount
        )

        var localOutputs: [String: PCMBuffer] = [:]
        var airPlayOutputs: [String: PCMBuffer] = [:]
        let isolated = Set(graph.isolatedAirPlayUIDs)

        for strip in strips where strip.isEnabled && !strip.isInput {
            let destRole: HALIORole = isolated.contains(strip.uid) ? .airPlayOutput : .localOutput
            let destChannels = destinationChannelCount(
                uid: strip.uid,
                devices: devices,
                fallback: mixChannelCount,
                role: destRole
            )
            let outputPeers = strips.filter { !$0.isInput }
            let weights = StripMix.channelWeights(
                for: strip,
                among: outputPeers,
                destinationChannelCount: destChannels
            )
            let routed = ChannelMixer.mix(
                sources: [
                    MixSource(
                        buffer: mixed,
                        gain: 1,
                        channelMap: Self.outputMap(strip, destChannels: destChannels),
                        channelGains: weights
                    )
                ],
                outputChannelCount: destChannels,
                frameCount: frameCount
            )
            if isolated.contains(strip.uid) {
                if airPlayFeeds[strip.uid] == nil
                    || airPlayFeeds[strip.uid]?.channelCount != destChannels {
                    airPlayFeeds[strip.uid] = AirPlaySafeBuffer(channelCount: destChannels)
                }
                // Producer only: AirPlay hardware callback is the sole consumer.
                airPlayFeeds[strip.uid]?.write(routed)
                airPlayOutputs[strip.uid] = PCMBuffer(frameCount: 0, channelCount: destChannels)
            } else {
                localOutputs[strip.uid] = routed
            }
        }

        return IOCycleResult(mixed: mixed, localOutputs: localOutputs, airPlayOutputs: airPlayOutputs)
    }

    public static func sources(
        from captures: [String: PCMBuffer],
        strips: [MixerStrip],
        destinationChannelCount: Int
    ) -> [MixSource] {
        StripMix.sources(
            from: captures,
            strips: strips,
            destinationChannelCount: destinationChannelCount
        )
    }

    private static func outputMap(_ strip: MixerStrip, destChannels: Int) -> [Int] {
        if strip.channelMap.count >= destChannels {
            return Array(strip.channelMap.prefix(destChannels))
        }
        return MixSource.identityMap(channelCount: destChannels)
    }

    /// HAL unit / route width for a device in a specific I/O role.
    /// Duplex music interfaces (e.g. 18in/20out) must open input units at inputChannelCount.
    public static func destinationChannelCount(
        uid: String,
        devices: [DeviceRecord],
        fallback: Int,
        role: HALIORole
    ) -> Int {
        if let device = devices.first(where: { $0.uid == uid }) {
            let count: Int
            switch role {
            case .input:
                count = device.inputChannelCount
            case .localOutput, .airPlayOutput:
                count = device.outputChannelCount
            }
            if count > 0 { return count }
        }
        return max(fallback, 1)
    }

    public static func mixChannelCount(devices: [DeviceRecord], strips: [MixerStrip], captures: [String: PCMBuffer]) -> Int {
        var maxChannels = 2
        for strip in strips where strip.isEnabled {
            if let device = devices.first(where: { $0.uid == strip.uid }) {
                maxChannels = max(maxChannels, strip.isInput ? device.inputChannelCount : device.outputChannelCount)
            }
            maxChannels = max(maxChannels, strip.channelMap.count)
        }
        for buffer in captures.values {
            maxChannels = max(maxChannels, buffer.channelCount)
        }
        return max(maxChannels, 2)
    }
}
