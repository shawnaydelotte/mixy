import Foundation

/// Isolated high-latency ring used only for AirPlay destinations.
/// Local devices never read or write this buffer; it is a separate clock domain feed.
public struct AirPlaySafeBuffer: Sendable {
    public let channelCount: Int
    public let frameCapacity: Int
    public let extraLatencyFrames: Int

    private var ring: LoopbackBuffer

    public init(
        channelCount: Int,
        frameCapacity: Int = AirPlayPolicy.airPlayBufferFrames * 4,
        extraLatencyFrames: Int = AirPlayPolicy.airPlayExtraLatencyFrames
    ) {
        self.channelCount = channelCount
        self.frameCapacity = max(frameCapacity, extraLatencyFrames + AirPlayPolicy.airPlayBufferFrames)
        self.extraLatencyFrames = extraLatencyFrames
        self.ring = LoopbackBuffer(channelCount: channelCount, frameCapacity: self.frameCapacity)
    }

    public var bufferedFrameCount: Int { ring.readableFrameCount }

    public var hasReachedLatencyTarget: Bool {
        ring.readableFrameCount >= extraLatencyFrames
    }

    public mutating func write(_ buffer: PCMBuffer) {
        ring.write(buffer)
    }

    /// Emits only surplus frames beyond the extra-latency cushion.
    /// Returns silence until the isolated path is primed; never drains the cushion.
    public mutating func read(frameCount: Int) -> PCMBuffer {
        let excess = ring.readableFrameCount - extraLatencyFrames
        guard excess > 0, frameCount > 0 else {
            return PCMBuffer(frameCount: frameCount, channelCount: channelCount)
        }
        let pulled = ring.read(frameCount: min(frameCount, excess))
        if pulled.frameCount == frameCount {
            return pulled
        }
        var padded = PCMBuffer(frameCount: frameCount, channelCount: channelCount)
        let copyCount = min(pulled.samples.count, padded.samples.count)
        if copyCount > 0 {
            padded.samples.replaceSubrange(0..<copyCount, with: pulled.samples[0..<copyCount])
        }
        return padded
    }

    public mutating func reset() {
        ring.reset()
    }
}
