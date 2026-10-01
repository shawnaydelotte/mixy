import CoreAudio
import XCTest
@testable import mixy

final class AirPlayPolicyTests: XCTestCase {
    private let airPlay = DeviceRecord(
        uid: "ap-homepod",
        name: "HomePod",
        manufacturer: "Apple Inc.",
        transportType: kAudioDeviceTransportTypeAirPlay,
        inputChannelCount: 0,
        outputChannelCount: 2
    )
    private let music = DeviceRecord(
        uid: "usb-scarlett",
        name: "Scarlett 18i20",
        manufacturer: "Focusrite",
        transportType: kAudioDeviceTransportTypeUSB,
        inputChannelCount: 18,
        outputChannelCount: 20
    )
    private let builtIn = DeviceRecord(
        uid: "builtin",
        name: "MacBook Air Speakers",
        manufacturer: "Apple Inc.",
        transportType: kAudioDeviceTransportTypeBuiltIn,
        inputChannelCount: 1,
        outputChannelCount: 2
    )

    func testAirPlayIsRejectedFromLocalClockGroup() {
        let graph = AirPlayPolicy.buildGraph(
            devices: [airPlay, music, builtIn],
            enabledUIDs: [airPlay.uid, music.uid, builtIn.uid]
        )
        XCTAssertEqual(graph.localClockDeviceUIDs, [music.uid, builtIn.uid])
        XCTAssertEqual(graph.isolatedAirPlayUIDs, [airPlay.uid])
        XCTAssertFalse(graph.localClockDeviceUIDs.contains(airPlay.uid))
        XCTAssertGreaterThan(graph.bufferFramesAirPlay, graph.bufferFramesLocal)
        XCTAssertEqual(graph.airPlayDestinations.count, 1)
        XCTAssertEqual(graph.airPlayDestinations[0].uid, airPlay.uid)
        XCTAssertEqual(graph.airPlayDestinations[0].bufferFrameSize, AirPlayPolicy.airPlayBufferFrames)
    }

    func testLocalAggregateBuilderThrowsOnAirPlay() {
        XCTAssertThrowsError(
            try AirPlayPolicy.localAggregateUIDs(including: [music, airPlay])
        ) { error in
            XCTAssertEqual(error as? MixPolicyError, .airPlayCannotJoinLocalClock(uid: airPlay.uid))
        }
        XCTAssertEqual(
            try AirPlayPolicy.localAggregateUIDs(including: [music, builtIn]),
            [music.uid, builtIn.uid]
        )
    }

    func testGraphUpdatesWhenAirPlayAppearsAndDisappears() {
        let without = AirPlayPolicy.buildGraph(
            devices: [music, builtIn],
            enabledUIDs: [music.uid, builtIn.uid]
        )
        XCTAssertTrue(without.isolatedAirPlayUIDs.isEmpty)

        let appeared = AirPlayPolicy.applyingDeviceChange(
            previous: without,
            devices: [music, builtIn, airPlay],
            enabledUIDs: [music.uid, builtIn.uid, airPlay.uid]
        )
        XCTAssertTrue(appeared.changed)
        XCTAssertEqual(appeared.graph.isolatedAirPlayUIDs, [airPlay.uid])
        XCTAssertEqual(appeared.graph.localClockDeviceUIDs, [music.uid, builtIn.uid])

        let disappeared = AirPlayPolicy.applyingDeviceChange(
            previous: appeared.graph,
            devices: [music, builtIn],
            enabledUIDs: [music.uid, builtIn.uid]
        )
        XCTAssertTrue(disappeared.changed)
        XCTAssertTrue(disappeared.graph.isolatedAirPlayUIDs.isEmpty)
    }

    func testAirPlaySafeBufferHoldsSilenceUntilLatencyIsPrimed() {
        var path = AirPlaySafeBuffer(channelCount: 2, frameCapacity: 64, extraLatencyFrames: 4)
        path.write(PCMBuffer(samples: [0.5, -0.5, 0.25, -0.25], channelCount: 2))
        let early = path.read(frameCount: 1)
        XCTAssertEqual(early.samples, [0, 0], "AirPlay path must not emit before extra latency is filled")

        path.write(PCMBuffer(samples: [0.1, 0.2, 0.3, 0.4, 0.9, -0.9], channelCount: 2))
        XCTAssertTrue(path.hasReachedLatencyTarget)
        XCTAssertGreaterThan(path.bufferedFrameCount, 4)
        let primed = path.read(frameCount: 1)
        XCTAssertEqual(primed.samples[0], 0.5, accuracy: 0.000_001)
        XCTAssertEqual(primed.samples[1], -0.5, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(path.bufferedFrameCount, 4, "cushion must remain after a pull")
    }

    func testDeviceBufferPeriodStaysWithinTheLatencyCeiling() {
        XCTAssertEqual(
            AirPlayPolicy.deviceBufferFrames(requested: 512, ceiling: 512, deviceCurrent: 128, deviceMinimum: 32),
            128,
            "a device already under the ceiling keeps the shorter period"
        )
        XCTAssertEqual(
            AirPlayPolicy.deviceBufferFrames(requested: 512, ceiling: 512, deviceCurrent: 4096, deviceMinimum: 64),
            512
        )
        XCTAssertEqual(
            AirPlayPolicy.deviceBufferFrames(requested: 512, ceiling: 512, deviceCurrent: 2048, deviceMinimum: 1024),
            2048,
            "a device whose minimum is above 512 is left on a period it can initialize"
        )
        XCTAssertNotEqual(
            AirPlayPolicy.deviceBufferFrames(requested: 512, ceiling: 512, deviceCurrent: 2048, deviceMinimum: 1024),
            512
        )
        XCTAssertEqual(
            AirPlayPolicy.deviceBufferFrames(requested: 4096, ceiling: 4096, deviceCurrent: 8192, deviceMinimum: 128),
            4096
        )
        XCTAssertEqual(
            AirPlayPolicy.deviceBufferFrames(requested: 4096, ceiling: 4096, deviceCurrent: 256, deviceMinimum: 64),
            256
        )
        XCTAssertEqual(AirPlayPolicy.streamSampleRate(deviceNominal: 44_100), 44_100)
        XCTAssertEqual(AirPlayPolicy.streamSampleRate(deviceNominal: 0), 48_000)
        XCTAssertEqual(AirPlayPolicy.streamSampleRate(deviceNominal: -1), 48_000)

        let graph = AirPlayPolicy.buildGraph(
            devices: [airPlay, music, builtIn],
            enabledUIDs: [airPlay.uid, music.uid, builtIn.uid]
        )
        XCTAssertLessThanOrEqual(graph.bufferFramesLocal, 512)
        XCTAssertLessThanOrEqual(graph.bufferFramesAirPlay, 4096)
        XCTAssertLessThanOrEqual(graph.extraLatencyFramesAirPlay, 4096)
        XCTAssertGreaterThan(graph.bufferFramesAirPlay, graph.bufferFramesLocal)
        XCTAssertGreaterThan(graph.extraLatencyFramesAirPlay, graph.bufferFramesLocal)
        XCTAssertEqual(graph.localBufferLabel, "\(graph.bufferFramesLocal) frames")
        XCTAssertEqual(graph.airPlayBufferLabel, "\(graph.bufferFramesAirPlay) frames")
        XCTAssertEqual(graph.airPlayExtraLatencyLabel, "\(graph.extraLatencyFramesAirPlay) frames")
    }

    @MainActor
    func testSettingsReadoutUsesTheGraphBufferSizes() {
        let graph = MixGraph(
            localClockDeviceUIDs: [builtIn.uid],
            isolatedAirPlayUIDs: [airPlay.uid],
            bufferFramesLocal: 128,
            bufferFramesAirPlay: 2048,
            extraLatencyFramesAirPlay: 1024
        )
        XCTAssertNotEqual(graph.bufferFramesLocal, AirPlayPolicy.localBufferFrames)
        XCTAssertNotEqual(graph.bufferFramesAirPlay, AirPlayPolicy.airPlayBufferFrames)
        XCTAssertEqual(graph.localBufferLabel, "128 frames")
        XCTAssertEqual(graph.airPlayBufferLabel, "2048 frames")
        XCTAssertEqual(graph.airPlayExtraLatencyLabel, "1024 frames")

        let controller = MixerController()
        XCTAssertEqual(controller.graph.localBufferLabel, "\(controller.graph.bufferFramesLocal) frames")
        XCTAssertEqual(controller.graph.airPlayBufferLabel, "\(controller.graph.bufferFramesAirPlay) frames")
        XCTAssertEqual(controller.graph.airPlayExtraLatencyLabel, "\(controller.graph.extraLatencyFramesAirPlay) frames")
        XCTAssertLessThanOrEqual(controller.graph.bufferFramesLocal, 512)
        XCTAssertLessThanOrEqual(controller.graph.bufferFramesAirPlay, 4096)
        XCTAssertLessThanOrEqual(controller.graph.extraLatencyFramesAirPlay, 4096)
        XCTAssertEqual(controller.io.currentGraph.bufferFramesLocal, controller.graph.bufferFramesLocal)
        XCTAssertEqual(controller.io.currentGraph.bufferFramesAirPlay, controller.graph.bufferFramesAirPlay)
        XCTAssertEqual(controller.io.currentGraph.extraLatencyFramesAirPlay, controller.graph.extraLatencyFramesAirPlay)
    }

    func testCoordinatorIsolatesAirPlayFromLocalFeed() {
        let coordinator = AudioIOCoordinator()
        coordinator.update(
            devices: [airPlay, music, builtIn],
            strips: [
                MixerStrip(uid: airPlay.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: false),
                MixerStrip(uid: music.uid, isEnabled: true, gainDecibels: 0, channelMap: MixSource.identityMap(channelCount: 8), isInput: true),
                MixerStrip(uid: builtIn.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: false)
            ]
        )
        let graph = coordinator.currentGraph
        XCTAssertEqual(graph.isolatedAirPlayUIDs, [airPlay.uid])
        XCTAssertFalse(graph.localClockDeviceUIDs.contains(airPlay.uid))
        XCTAssertFalse(graph.localClockDeviceUIDs.contains(music.uid), "input strips must not join the output clock group")
        XCTAssertTrue(graph.localClockDeviceUIDs.contains(builtIn.uid))
    }
}
