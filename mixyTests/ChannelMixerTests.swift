import XCTest
@testable import mixy

final class ChannelMixerTests: XCTestCase {
    func testTwoMultiChannelSourcesAtKnownGainsMatchArithmeticSum() {
        let sourceA = MixSource(
            buffer: PCMBuffer(
                samples: [
                    1.0, 2.0, 3.0, 4.0,
                    5.0, 6.0, 7.0, 8.0
                ],
                channelCount: 4
            ),
            gain: 0.5,
            channelMap: [0, 1, 2, 3]
        )
        let sourceB = MixSource(
            buffer: PCMBuffer(
                samples: [
                    10.0, 20.0,
                    30.0, 40.0
                ],
                channelCount: 2
            ),
            gain: 2.0,
            channelMap: [0, 1, -1, -1]
        )

        let mixed = ChannelMixer.mix(
            sources: [sourceA, sourceB],
            outputChannelCount: 4,
            frameCount: 2
        )

        XCTAssertEqual(mixed.channelCount, 4)
        XCTAssertEqual(mixed.frameCount, 2)

        XCTAssertEqual(mixed[frame: 0, channel: 0], 1.0 * 0.5 + 10.0 * 2.0, accuracy: 0.000_001)
        XCTAssertEqual(mixed[frame: 0, channel: 1], 2.0 * 0.5 + 20.0 * 2.0, accuracy: 0.000_001)
        XCTAssertEqual(mixed[frame: 0, channel: 2], 3.0 * 0.5, accuracy: 0.000_001)
        XCTAssertEqual(mixed[frame: 0, channel: 3], 4.0 * 0.5, accuracy: 0.000_001)

        XCTAssertEqual(mixed[frame: 1, channel: 0], 5.0 * 0.5 + 30.0 * 2.0, accuracy: 0.000_001)
        XCTAssertEqual(mixed[frame: 1, channel: 1], 6.0 * 0.5 + 40.0 * 2.0, accuracy: 0.000_001)
        XCTAssertEqual(mixed[frame: 1, channel: 2], 7.0 * 0.5, accuracy: 0.000_001)
        XCTAssertEqual(mixed[frame: 1, channel: 3], 8.0 * 0.5, accuracy: 0.000_001)
    }

    func testChannelMapRoutesSourceChannelOntoDifferentDestination() {
        let source = MixSource(
            buffer: PCMBuffer(samples: [0.25, 0.75], channelCount: 2),
            gain: 1.0,
            channelMap: [1, 0]
        )
        let mixed = ChannelMixer.mix(sources: [source], outputChannelCount: 2, frameCount: 1)
        XCTAssertEqual(mixed.samples[0], 0.75, accuracy: 0.000_001)
        XCTAssertEqual(mixed.samples[1], 0.25, accuracy: 0.000_001)
    }

    func testZeroGainDropsSource() {
        let source = MixSource(
            buffer: PCMBuffer(samples: [1, 1], channelCount: 2),
            gain: 0,
            channelMap: [0, 1]
        )
        let mixed = ChannelMixer.mix(sources: [source], outputChannelCount: 2, frameCount: 1)
        XCTAssertEqual(mixed.samples, [0, 0])
    }
}
