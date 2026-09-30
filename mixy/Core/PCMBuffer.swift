import Foundation

/// Interleaved 32-bit float PCM.
public struct PCMBuffer: Equatable, Sendable {
    public var samples: [Float]
    public var channelCount: Int

    public init(samples: [Float], channelCount: Int) {
        precondition(channelCount > 0, "channelCount must be positive")
        self.samples = samples
        self.channelCount = channelCount
    }

    public init(frameCount: Int, channelCount: Int, repeating value: Float = 0) {
        precondition(channelCount > 0, "channelCount must be positive")
        precondition(frameCount >= 0, "frameCount must be non-negative")
        self.samples = [Float](repeating: value, count: frameCount * channelCount)
        self.channelCount = channelCount
    }

    public var frameCount: Int {
        guard channelCount > 0 else { return 0 }
        return samples.count / channelCount
    }

    public subscript(frame frame: Int, channel channel: Int) -> Float {
        get { samples[frame * channelCount + channel] }
        set { samples[frame * channelCount + channel] = newValue }
    }
}

/// Linear gain helpers used by the mixer UI and I/O path.
public enum AmplitudeGain: Sendable {
    public static let silenceDecibels: Float = -96

    public static func linear(fromDecibels db: Float) -> Float {
        if db <= silenceDecibels { return 0 }
        return pow(10, db / 20)
    }

    public static func decibels(fromLinear linear: Float) -> Float {
        if linear <= 0 { return silenceDecibels }
        return 20 * log10(linear)
    }
}
