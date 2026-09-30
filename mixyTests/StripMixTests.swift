import CoreAudio
import XCTest
@testable import mixy

final class StripMixTests: XCTestCase {
    private let bus = DeviceRecord(
        uid: "speakers",
        name: "Speakers",
        transportType: kAudioDeviceTransportTypeBuiltIn,
        inputChannelCount: 0,
        outputChannelCount: 2
    )
    private let srcA = DeviceRecord(
        uid: "in-a",
        name: "Interface A",
        transportType: kAudioDeviceTransportTypeUSB,
        inputChannelCount: 2,
        outputChannelCount: 0
    )
    private let srcB = DeviceRecord(
        uid: "in-b",
        name: "Interface B",
        transportType: kAudioDeviceTransportTypeUSB,
        inputChannelCount: 2,
        outputChannelCount: 0
    )

    private func strip(
        uid: String,
        isInput: Bool,
        fader: Float,
        muted: Bool = false,
        soloed: Bool = false,
        pan: Float = 0,
        map: [Int] = [0, 1]
    ) -> MixerStrip {
        MixerStrip(
            uid: uid,
            isEnabled: true,
            gainDecibels: AmplitudeGain.decibels(fromLinear: fader),
            channelMap: map,
            isInput: isInput,
            isMuted: muted,
            isSoloed: soloed,
            pan: pan
        )
    }

    func testTwoFadersSumThroughShippedStripSources() {
        let strips = [
            strip(uid: srcA.uid, isInput: true, fader: 0.5),
            strip(uid: srcB.uid, isInput: true, fader: 2.0)
        ]
        let captures = [
            srcA.uid: PCMBuffer(samples: [1.0, 3.0, 5.0, 7.0], channelCount: 2),
            srcB.uid: PCMBuffer(samples: [10.0, 20.0, 30.0, 40.0], channelCount: 2)
        ]
        let sources = StripMix.sources(from: captures, strips: strips, destinationChannelCount: 2)
        let mixed = ChannelMixer.mix(sources: sources, outputChannelCount: 2, frameCount: 2)
        XCTAssertEqual(mixed[frame: 0, channel: 0], 1.0 * 0.5 + 10.0 * 2.0, accuracy: 0.000_1)
        XCTAssertEqual(mixed[frame: 0, channel: 1], 3.0 * 0.5 + 20.0 * 2.0, accuracy: 0.000_1)
        XCTAssertEqual(mixed[frame: 1, channel: 0], 5.0 * 0.5 + 30.0 * 2.0, accuracy: 0.000_1)
        XCTAssertEqual(mixed[frame: 1, channel: 1], 7.0 * 0.5 + 40.0 * 2.0, accuracy: 0.000_1)
    }

    func testMuteZerosThatSource() {
        let strips = [
            strip(uid: srcA.uid, isInput: true, fader: 1.0, muted: true),
            strip(uid: srcB.uid, isInput: true, fader: 1.0)
        ]
        let captures = [
            srcA.uid: PCMBuffer(samples: [9.0, 9.0], channelCount: 2),
            srcB.uid: PCMBuffer(samples: [0.25, 0.5], channelCount: 2)
        ]
        let sources = StripMix.sources(from: captures, strips: strips, destinationChannelCount: 2)
        let mixed = ChannelMixer.mix(sources: sources, outputChannelCount: 2, frameCount: 1)
        XCTAssertEqual(mixed.samples[0], 0.25, accuracy: 0.000_1)
        XCTAssertEqual(mixed.samples[1], 0.5, accuracy: 0.000_1)
        XCTAssertEqual(StripMix.effectiveLinearGain(for: strips[0], among: strips), 0)
    }

    func testSoloIsolatesSoloedSource() {
        let strips = [
            strip(uid: srcA.uid, isInput: true, fader: 1.0, soloed: true),
            strip(uid: srcB.uid, isInput: true, fader: 1.0)
        ]
        let captures = [
            srcA.uid: PCMBuffer(samples: [0.4, 0.8], channelCount: 2),
            srcB.uid: PCMBuffer(samples: [100, 100], channelCount: 2)
        ]
        let sources = StripMix.sources(from: captures, strips: strips, destinationChannelCount: 2)
        let mixed = ChannelMixer.mix(sources: sources, outputChannelCount: 2, frameCount: 1)
        XCTAssertEqual(mixed.samples[0], 0.4, accuracy: 0.000_1)
        XCTAssertEqual(mixed.samples[1], 0.8, accuracy: 0.000_1)
        XCTAssertTrue(StripMix.isSoloActive(among: strips))
        XCTAssertEqual(StripMix.effectiveLinearGain(for: strips[1], among: strips), 0)
    }

    func testPanLeftAndRightBiasFirstTwoChannels() {
        XCTAssertEqual(StripMix.stereoPanWeights(0).left, 1, accuracy: 0.000_1)
        XCTAssertEqual(StripMix.stereoPanWeights(0).right, 1, accuracy: 0.000_1)
        XCTAssertEqual(StripMix.stereoPanWeights(-1).left, 1, accuracy: 0.000_1)
        XCTAssertEqual(StripMix.stereoPanWeights(-1).right, 0, accuracy: 0.000_1)
        XCTAssertEqual(StripMix.stereoPanWeights(1).left, 0, accuracy: 0.000_1)
        XCTAssertEqual(StripMix.stereoPanWeights(1).right, 1, accuracy: 0.000_1)

        let left = strip(uid: srcA.uid, isInput: true, fader: 1.0, pan: -1)
        let right = strip(uid: srcA.uid, isInput: true, fader: 1.0, pan: 1)
        let capture = [srcA.uid: PCMBuffer(samples: [2.0, 4.0], channelCount: 2)]
        let leftMix = ChannelMixer.mix(
            sources: StripMix.sources(from: capture, strips: [left], destinationChannelCount: 2),
            outputChannelCount: 2,
            frameCount: 1
        )
        let rightMix = ChannelMixer.mix(
            sources: StripMix.sources(from: capture, strips: [right], destinationChannelCount: 2),
            outputChannelCount: 2,
            frameCount: 1
        )
        XCTAssertEqual(leftMix.samples[0], 2.0, accuracy: 0.000_1)
        XCTAssertEqual(leftMix.samples[1], 0.0, accuracy: 0.000_1)
        XCTAssertEqual(rightMix.samples[0], 0.0, accuracy: 0.000_1)
        XCTAssertEqual(rightMix.samples[1], 4.0, accuracy: 0.000_1)
    }

    func testMonoCaptureFeedsBothStereoDestsBeforePan() {
        let mic = DeviceRecord(
            uid: "builtin-mic",
            name: "MacBook Air Microphone",
            transportType: kAudioDeviceTransportTypeBuiltIn,
            inputChannelCount: 1,
            outputChannelCount: 0
        )
        // Identity map a 1ch HAL input actually gets: dest 1 is missing, not explicit -1.
        let identityMono = MixerStrip(
            uid: mic.uid,
            isEnabled: true,
            gainDecibels: 0,
            channelMap: MixSource.identityMap(channelCount: 1),
            isInput: true
        )
        XCTAssertEqual(identityMono.channelMap, [0])
        XCTAssertEqual(
            StripMix.destChannelMap(stripMap: [0], sourceChannelCount: 1, destinationChannelCount: 2),
            [0, 0]
        )

        let capture = [mic.uid: PCMBuffer(samples: [0.8], channelCount: 1)]
        let centerSources = StripMix.sources(
            from: capture,
            strips: [identityMono],
            destinationChannelCount: 2
        )
        XCTAssertEqual(centerSources.first?.channelMap, [0, 0])
        let center = ChannelMixer.mix(sources: centerSources, outputChannelCount: 2, frameCount: 1)
        XCTAssertEqual(center.samples[0], 0.8, accuracy: 0.000_1)
        XCTAssertEqual(center.samples[1], 0.8, accuracy: 0.000_1)

        var pannedRight = identityMono
        pannedRight.pan = 1
        let right = ChannelMixer.mix(
            sources: StripMix.sources(from: capture, strips: [pannedRight], destinationChannelCount: 2),
            outputChannelCount: 2,
            frameCount: 1
        )
        XCTAssertEqual(right.samples[0], 0.0, accuracy: 0.000_1)
        XCTAssertEqual(right.samples[1], 0.8, accuracy: 0.000_1)

        // ChannelMixer itself must still write dest 1 from a raw 1ch map [0].
        let raw = ChannelMixer.mix(
            sources: [
                MixSource(buffer: PCMBuffer(samples: [0.8], channelCount: 1), gain: 1, channelMap: [0])
            ],
            outputChannelCount: 2,
            frameCount: 1
        )
        XCTAssertEqual(raw.samples[0], 0.8, accuracy: 0.000_1)
        XCTAssertEqual(raw.samples[1], 0.8, accuracy: 0.000_1)

        let io = AudioIOCoordinator()
        io.update(
            devices: [mic, bus],
            strips: [identityMono, MixerStrip(uid: bus.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: false)]
        )
        var frames: [Float] = [0.8]
        frames.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(
                role: .input,
                uid: mic.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 1,
                channelCount: 1
            )
        }
        var local = [Float](repeating: -1, count: 2)
        local.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(
                role: .localOutput,
                uid: bus.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 1,
                channelCount: 2
            )
        }
        XCTAssertEqual(local[0], 0.8, accuracy: 0.000_1)
        XCTAssertEqual(local[1], 0.8, accuracy: 0.000_1)
    }

    func testIOCycleAppliesStripControlsOnHALCallbackPath() {
        let io = AudioIOCoordinator()
        let mutedA = strip(uid: srcA.uid, isInput: true, fader: 1.0, muted: true)
        let liveB = strip(uid: srcB.uid, isInput: true, fader: 0.5, pan: -1)
        let out = MixerStrip(uid: bus.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: false)
        io.update(devices: [srcA, srcB, bus], strips: [mutedA, liveB, out])

        var framesA: [Float] = [8, 8]
        var framesB: [Float] = [6, 10]
        framesA.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(
                role: .input,
                uid: srcA.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 1,
                channelCount: 2
            )
        }
        framesB.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(
                role: .input,
                uid: srcB.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 1,
                channelCount: 2
            )
        }
        var local = [Float](repeating: -1, count: 2)
        local.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(
                role: .localOutput,
                uid: bus.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 1,
                channelCount: 2
            )
        }
        // A muted; B fader 0.5 and pan full left → L = 6*0.5, R = 0
        XCTAssertEqual(local[0], 6.0 * 0.5, accuracy: 0.000_1)
        XCTAssertEqual(local[1], 0.0, accuracy: 0.000_1)
    }

    func testMixIOCycleRunUsesStripMixForSoloedInput() {
        var feeds: [String: AirPlaySafeBuffer] = [:]
        let strips = [
            strip(uid: srcA.uid, isInput: true, fader: 1.0, soloed: true),
            strip(uid: srcB.uid, isInput: true, fader: 1.0),
            MixerStrip(uid: bus.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: false)
        ]
        let graph = AirPlayPolicy.buildGraph(
            devices: [srcA, srcB, bus],
            enabledUIDs: [srcA.uid, srcB.uid, bus.uid]
        )
        let result = MixIOCycle.run(
            captures: [
                srcA.uid: PCMBuffer(samples: [1.5, 2.5], channelCount: 2),
                srcB.uid: PCMBuffer(samples: [9, 9], channelCount: 2)
            ],
            strips: strips,
            devices: [srcA, srcB, bus],
            graph: graph,
            airPlayFeeds: &feeds,
            frameCount: 1,
            mixChannelCount: 2
        )
        XCTAssertEqual(result.mixed.samples[0], Float(1.5), accuracy: 0.000_1)
        XCTAssertEqual(result.mixed.samples[1], Float(2.5), accuracy: 0.000_1)
        let dest = result.localOutputs[bus.uid]?.samples.first ?? Float.nan
        XCTAssertEqual(dest, Float(1.5), accuracy: 0.000_1)
    }

    func testMixerViewSourceIsChannelStripBank() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mixy/MixerView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("VerticalFader"), "main window must include a fader")
        XCTAssertTrue(source.contains("setMuted"), "main window must bind mute")
        XCTAssertTrue(source.contains("setSoloed"), "main window must bind solo")
        XCTAssertTrue(source.contains("setPan"), "main window must bind pan")
        XCTAssertTrue(source.contains("ChannelStripView"))
        XCTAssertFalse(source.contains("Hello, world!"))
    }
}
