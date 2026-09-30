import Foundation

/// One source contributing to a mix: interleaved frames, linear gain, and dest←src map.
public struct MixSource: Equatable, Sendable {
    public var buffer: PCMBuffer
    public var gain: Float
    /// `channelMap[destinationChannel] = sourceChannel`, or `-1` for silence on that dest.
    public var channelMap: [Int]
    /// Per-destination weights (pan/balance). Empty means unity on every dest channel.
    public var channelGains: [Float]

    public init(buffer: PCMBuffer, gain: Float, channelMap: [Int], channelGains: [Float] = []) {
        self.buffer = buffer
        self.gain = gain
        self.channelMap = channelMap
        self.channelGains = channelGains
    }

    /// Identity map for `count` channels (dest N reads source N).
    public static func identityMap(channelCount: Int) -> [Int] {
        Array(0..<channelCount)
    }
}

/// Multi-source mix with per-source gain and channel mapping. Real-time safe (no allocation
/// beyond the returned buffer).
public enum ChannelMixer: Sendable {
    public static func mix(
        sources: [MixSource],
        outputChannelCount: Int,
        frameCount: Int
    ) -> PCMBuffer {
        precondition(outputChannelCount > 0, "outputChannelCount must be positive")
        precondition(frameCount >= 0, "frameCount must be non-negative")
        var output = PCMBuffer(frameCount: frameCount, channelCount: outputChannelCount)
        mix(
            sources: sources,
            outputChannelCount: outputChannelCount,
            frameCount: frameCount,
            into: &output.samples
        )
        return output
    }

    public static func mix(
        sources: [MixSource],
        outputChannelCount: Int,
        frameCount: Int,
        into output: inout [Float]
    ) {
        let needed = frameCount * outputChannelCount
        if output.count < needed {
            output.append(contentsOf: repeatElement(0, count: needed - output.count))
        }
        for i in 0..<needed {
            output[i] = 0
        }
        guard frameCount > 0 else { return }

        for source in sources {
            let gain = source.gain
            if gain == 0 { continue }
            let srcChannels = source.buffer.channelCount
            let srcFrames = source.buffer.frameCount
            let samples = source.buffer.samples
            for frame in 0..<frameCount {
                guard frame < srcFrames else { break }
                let srcBase = frame * srcChannels
                let destBase = frame * outputChannelCount
                for destCh in 0..<outputChannelCount {
                    let srcCh: Int
                    if destCh < source.channelMap.count {
                        srcCh = source.channelMap[destCh]
                    } else if destCh < srcChannels {
                        srcCh = destCh
                    } else if srcChannels == 1, destCh < 2 {
                        srcCh = 0
                    } else {
                        continue
                    }
                    guard srcCh >= 0, srcCh < srcChannels else { continue }
                    let srcIndex = srcBase + srcCh
                    guard srcIndex < samples.count else { continue }
                    var sample = samples[srcIndex] * gain
                    if destCh < source.channelGains.count {
                        sample *= source.channelGains[destCh]
                    }
                    output[destBase + destCh] += sample
                }
            }
        }
    }
}
