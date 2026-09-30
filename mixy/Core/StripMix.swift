import Foundation

/// Turns strip fader/mute/solo/pan into mix sources. UI, tests, and AUHAL share this path.
public enum StripMix: Sendable {
    /// Linear balance: pan `-1` is full left, `0` is unity L/R, `+1` is full right.
    public static func stereoPanWeights(_ pan: Float) -> (left: Float, right: Float) {
        let clamped = min(max(pan, -1), 1)
        let left = clamped <= 0 ? 1 : 1 - clamped
        let right = clamped >= 0 ? 1 : 1 + clamped
        return (left, right)
    }

    /// `true` when any enabled peer in the same I/O direction is soloed.
    public static func isSoloActive(among peers: [MixerStrip]) -> Bool {
        peers.contains { $0.isEnabled && $0.isSoloed }
    }

    /// Fader linear gain after mute and solo. Zero if muted, or if another peer is soloed.
    public static func effectiveLinearGain(for strip: MixerStrip, among peers: [MixerStrip]) -> Float {
        if !strip.isEnabled { return 0 }
        if strip.isMuted { return 0 }
        if isSoloActive(among: peers), !strip.isSoloed { return 0 }
        return strip.linearGain
    }

    /// Dest-channel weights: pan on the first two channels, unity on the rest, times effective gain.
    public static func channelWeights(
        for strip: MixerStrip,
        among peers: [MixerStrip],
        destinationChannelCount: Int
    ) -> [Float] {
        let gain = effectiveLinearGain(for: strip, among: peers)
        if gain == 0 {
            return [Float](repeating: 0, count: max(destinationChannelCount, 0))
        }
        let pan = stereoPanWeights(strip.pan)
        return (0..<destinationChannelCount).map { channel in
            switch channel {
            case 0: return gain * pan.left
            case 1: return gain * pan.right
            default: return gain
            }
        }
    }

    /// Expands a strip map so a 1ch source feeds both stereo dests (L and R)
    /// before pan weights. Explicit extra dest entries (including `-1`) are kept.
    public static func destChannelMap(
        stripMap: [Int],
        sourceChannelCount: Int,
        destinationChannelCount: Int
    ) -> [Int] {
        var map = stripMap
        if sourceChannelCount == 1 {
            while map.count < min(2, destinationChannelCount) {
                map.append(0)
            }
        } else {
            while map.count < destinationChannelCount, map.count < sourceChannelCount {
                map.append(map.count)
            }
        }
        while map.count < destinationChannelCount {
            map.append(-1)
        }
        if map.count > destinationChannelCount {
            map = Array(map.prefix(destinationChannelCount))
        }
        return map
    }

    /// Input strips + captures → `MixSource`s consumed by `ChannelMixer` / `MixIOCycle`.
    public static func sources(
        from captures: [String: PCMBuffer],
        strips: [MixerStrip],
        destinationChannelCount: Int
    ) -> [MixSource] {
        let inputs = strips.filter(\.isInput)
        var result: [MixSource] = []
        for strip in inputs where strip.isEnabled {
            guard let captured = captures[strip.uid] else { continue }
            let weights = channelWeights(
                for: strip,
                among: inputs,
                destinationChannelCount: destinationChannelCount
            )
            result.append(
                MixSource(
                    buffer: captured,
                    gain: 1,
                    channelMap: destChannelMap(
                        stripMap: strip.channelMap,
                        sourceChannelCount: captured.channelCount,
                        destinationChannelCount: destinationChannelCount
                    ),
                    channelGains: weights
                )
            )
        }
        return result
    }
}
