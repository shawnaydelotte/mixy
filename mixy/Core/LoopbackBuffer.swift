import Foundation

/// Soundflower-like ring: frames written to the virtual output are available as input.
public struct LoopbackBuffer: Sendable {
    public let channelCount: Int
    public let frameCapacity: Int

    private var storage: [Float]
    private var writeFrame: Int
    private var availableFrames: Int

    public init(channelCount: Int, frameCapacity: Int) {
        precondition(channelCount > 0, "channelCount must be positive")
        precondition(frameCapacity > 0, "frameCapacity must be positive")
        self.channelCount = channelCount
        self.frameCapacity = frameCapacity
        self.storage = [Float](repeating: 0, count: frameCapacity * channelCount)
        self.writeFrame = 0
        self.availableFrames = 0
    }

    public var readableFrameCount: Int { availableFrames }

    /// Writes interleaved frames. Extra source channels are dropped; missing dest channels are 0.
    public mutating func write(_ buffer: PCMBuffer) {
        write(samples: buffer.samples, frameCount: buffer.frameCount, channelCount: buffer.channelCount)
    }

    public mutating func write(samples: [Float], frameCount: Int, channelCount srcChannels: Int) {
        guard frameCount > 0, srcChannels > 0 else { return }
        let framesToWrite = min(frameCount, frameCapacity)
        let start = frameCount - framesToWrite
        for i in 0..<framesToWrite {
            let srcFrame = start + i
            let destFrame = writeFrame
            let destBase = destFrame * channelCount
            let srcBase = srcFrame * srcChannels
            for ch in 0..<channelCount {
                if ch < srcChannels, srcBase + ch < samples.count {
                    storage[destBase + ch] = samples[srcBase + ch]
                } else {
                    storage[destBase + ch] = 0
                }
            }
            writeFrame = (writeFrame + 1) % frameCapacity
            if availableFrames < frameCapacity {
                availableFrames += 1
            }
        }
    }

    /// Reads the oldest unread frames. Underrun frames are zeros.
    public mutating func read(frameCount: Int) -> PCMBuffer {
        var out = PCMBuffer(frameCount: frameCount, channelCount: channelCount)
        guard frameCount > 0 else { return out }
        let readStart = (writeFrame - availableFrames + frameCapacity) % frameCapacity
        for i in 0..<frameCount {
            if i < availableFrames {
                let srcFrame = (readStart + i) % frameCapacity
                let srcBase = srcFrame * channelCount
                let destBase = i * channelCount
                for ch in 0..<channelCount {
                    out.samples[destBase + ch] = storage[srcBase + ch]
                }
            }
        }
        let consumed = min(frameCount, availableFrames)
        availableFrames -= consumed
        return out
    }

    public mutating func reset() {
        storage = [Float](repeating: 0, count: frameCapacity * channelCount)
        writeFrame = 0
        availableFrames = 0
    }
}
