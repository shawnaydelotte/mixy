import XCTest
@testable import mixy

final class LoopbackTests: XCTestCase {
    func testWriteThenReadReturnsMatchingSampleValues() {
        var loopback = LoopbackBuffer(channelCount: 2, frameCapacity: 64)
        let written = PCMBuffer(
            samples: [
                0.125, -0.25,
                0.5, 0.75,
                -1.0, 0.0625
            ],
            channelCount: 2
        )

        loopback.write(written)
        let read = loopback.read(frameCount: written.frameCount)

        XCTAssertEqual(read.channelCount, 2)
        XCTAssertEqual(read.frameCount, 3)
        XCTAssertEqual(read.samples.count, written.samples.count)
        for index in written.samples.indices {
            XCTAssertEqual(
                read.samples[index],
                written.samples[index],
                accuracy: 0.000_001,
                "loopback sample \(index) must match the written frame"
            )
        }
    }

    func testMultiChannelRoundTripThroughCoordinator() {
        let coordinator = AudioIOCoordinator()
        var samples: [Float] = []
        for frame in 0..<8 {
            for channel in 0..<8 {
                samples.append(Float(frame) * 0.1 + Float(channel) * 0.01)
            }
        }
        let written = PCMBuffer(samples: samples, channelCount: 8)
        let read = coordinator.loopbackRoundTrip(written)
        XCTAssertEqual(read.channelCount, 8)
        XCTAssertEqual(read.frameCount, 8)
        for index in samples.indices {
            XCTAssertEqual(read.samples[index], samples[index], accuracy: 0.000_001)
        }
    }

    func testUnderrunReturnsZerosAfterDrain() {
        var loopback = LoopbackBuffer(channelCount: 2, frameCapacity: 16)
        loopback.write(PCMBuffer(samples: [0.3, 0.4], channelCount: 2))
        _ = loopback.read(frameCount: 1)
        let empty = loopback.read(frameCount: 2)
        XCTAssertEqual(empty.samples, [0, 0, 0, 0])
    }
}
