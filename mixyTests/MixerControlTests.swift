import CoreAudio
import XCTest
@testable import mixy

/// Drives every strip control through MixerController into the shipped HAL I/O cycle.
final class MixerControlTests: XCTestCase {
    private let mic = DeviceRecord(
        uid: "ctrl-mic",
        name: "Test Mic",
        transportType: kAudioDeviceTransportTypeBuiltIn,
        inputChannelCount: 2,
        outputChannelCount: 0
    )
    private let app = DeviceRecord(
        uid: "ctrl-app",
        name: "Test App",
        transportType: kAudioDeviceTransportTypeVirtual,
        inputChannelCount: 2,
        outputChannelCount: 0
    )
    private let speakers = DeviceRecord(
        uid: "ctrl-speakers",
        name: "Test Speakers",
        transportType: kAudioDeviceTransportTypeBuiltIn,
        inputChannelCount: 0,
        outputChannelCount: 2
    )

    private var micSource: InputSource { InputSource(hal: mic) }
    private var appSource: InputSource {
        InputSource(
            uid: app.uid,
            name: app.name,
            kind: .application,
            inputChannelCount: 2,
            transportName: "Application",
            isRunningOutput: true
        )
    }
    private var speakerDest: OutputDestination { OutputDestination(hal: speakers) }

    @MainActor
    private func armedController() -> MixerController {
        let controller = MixerController()
        controller.devices = [mic, app, speakers]
        controller.inputSources = [micSource, appSource]
        controller.destinations = [speakerDest]
        controller.addInputToMixer(micSource)
        controller.addInputToMixer(appSource)
        controller.addOutputToMixer(speakerDest)
        return controller
    }

    @MainActor
    private func renderLocal(
        _ controller: MixerController,
        micFrames: [Float] = [1.0, 1.0],
        appFrames: [Float] = [10.0, 10.0]
    ) -> [Float] {
        var micBuf = micFrames
        var appBuf = appFrames
        micBuf.withUnsafeMutableBufferPointer { pointer in
            controller.io.handleHardwareIO(
                role: .input,
                uid: mic.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 1,
                channelCount: 2
            )
        }
        appBuf.withUnsafeMutableBufferPointer { pointer in
            controller.io.handleHardwareIO(
                role: .input,
                uid: app.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 1,
                channelCount: 2
            )
        }
        var local = [Float](repeating: -99, count: 2)
        local.withUnsafeMutableBufferPointer { pointer in
            controller.io.handleHardwareIO(
                role: .localOutput,
                uid: speakers.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 1,
                channelCount: 2
            )
        }
        return local
    }

    @MainActor
    private func inputStrip(_ controller: MixerController, uid: String) -> MixerStrip {
        controller.strips.first { $0.uid == uid && $0.isInput }!
    }

    @MainActor
    private func outputStrip(_ controller: MixerController) -> MixerStrip {
        controller.strips.first { $0.uid == speakers.uid && !$0.isInput }!
    }

    @MainActor
    func testFaderMuteSoloPanAndEnableChangeShippedIOCycle() {
        let controller = armedController()
        let unity = renderLocal(controller)
        XCTAssertEqual(unity[0], 11.0, accuracy: 0.000_1)
        XCTAssertEqual(unity[1], 11.0, accuracy: 0.000_1)

        controller.setGain(inputStrip(controller, uid: mic.uid), decibels: AmplitudeGain.decibels(fromLinear: 0.5))
        let fadedGain = controller.liveStrip(id: inputStrip(controller, uid: mic.uid).id)?.gainDecibels
        XCTAssertEqual(fadedGain ?? .nan, AmplitudeGain.decibels(fromLinear: 0.5), accuracy: 0.000_1)
        let faded = renderLocal(controller)
        XCTAssertEqual(faded[0], 1.0 * 0.5 + 10.0, accuracy: 0.000_1)
        XCTAssertEqual(faded[1], 1.0 * 0.5 + 10.0, accuracy: 0.000_1)

        controller.setMuted(inputStrip(controller, uid: app.uid), muted: true)
        XCTAssertTrue(controller.liveStrip(id: inputStrip(controller, uid: app.uid).id)?.isMuted == true)
        let muted = renderLocal(controller)
        XCTAssertEqual(muted[0], 0.5, accuracy: 0.000_1)
        XCTAssertEqual(muted[1], 0.5, accuracy: 0.000_1)

        controller.setMuted(inputStrip(controller, uid: app.uid), muted: false)
        controller.setSoloed(inputStrip(controller, uid: mic.uid), soloed: true)
        XCTAssertTrue(controller.liveStrip(id: inputStrip(controller, uid: mic.uid).id)?.isSoloed == true)
        let soloed = renderLocal(controller)
        XCTAssertEqual(soloed[0], 0.5, accuracy: 0.000_1)
        XCTAssertEqual(soloed[1], 0.5, accuracy: 0.000_1)

        controller.setSoloed(inputStrip(controller, uid: mic.uid), soloed: false)
        controller.setGain(inputStrip(controller, uid: mic.uid), decibels: 0)
        controller.setPan(inputStrip(controller, uid: mic.uid), pan: -1)
        let pan = controller.liveStrip(id: inputStrip(controller, uid: mic.uid).id)?.pan ?? 99
        XCTAssertEqual(pan, -1, accuracy: 0.000_1)
        let panned = renderLocal(controller, appFrames: [0, 0])
        XCTAssertEqual(panned[0], 1.0, accuracy: 0.000_1)
        XCTAssertEqual(panned[1], 0.0, accuracy: 0.000_1)

        controller.setPan(inputStrip(controller, uid: mic.uid), pan: 0)
        controller.setEnabled(inputStrip(controller, uid: mic.uid), enabled: false)
        XCTAssertFalse(controller.liveStrip(id: inputStrip(controller, uid: mic.uid).id)?.isEnabled ?? true)
        let off = renderLocal(controller)
        XCTAssertEqual(off[0], 10.0, accuracy: 0.000_1)
        XCTAssertEqual(off[1], 10.0, accuracy: 0.000_1)
    }

    @MainActor
    func testOutputMuteFaderAndEnableSilenceOrScaleLocalBus() {
        let controller = armedController()
        controller.setMuted(inputStrip(controller, uid: app.uid), muted: true)
        let unity = renderLocal(controller)
        XCTAssertEqual(unity[0], 1.0, accuracy: 0.000_1)

        controller.setGain(outputStrip(controller), decibels: AmplitudeGain.decibels(fromLinear: 0.25))
        let faded = renderLocal(controller)
        XCTAssertEqual(faded[0], 0.25, accuracy: 0.000_1)
        XCTAssertEqual(faded[1], 0.25, accuracy: 0.000_1)

        controller.setMuted(outputStrip(controller), muted: true)
        let muted = renderLocal(controller)
        XCTAssertEqual(muted[0], 0, accuracy: 0.000_1)
        XCTAssertEqual(muted[1], 0, accuracy: 0.000_1)

        controller.setMuted(outputStrip(controller), muted: false)
        controller.setGain(outputStrip(controller), decibels: 0)
        controller.setEnabled(outputStrip(controller), enabled: false)
        let off = renderLocal(controller)
        XCTAssertEqual(off[0], 0, accuracy: 0.000_1)
        XCTAssertEqual(off[1], 0, accuracy: 0.000_1)
        XCTAssertFalse(controller.selectedAudioUIDs.contains(speakers.uid))
    }

    @MainActor
    func testOutputMuteAppliesOnNextOutputCallbackWithoutNewInput() {
        let controller = armedController()
        controller.setMuted(inputStrip(controller, uid: app.uid), muted: true)
        let armed = renderLocal(controller)
        XCTAssertEqual(armed[0], 1.0, accuracy: 0.000_1)

        controller.setMuted(outputStrip(controller), muted: true)
        var local = [Float](repeating: -99, count: 2)
        local.withUnsafeMutableBufferPointer { pointer in
            controller.io.handleHardwareIO(
                role: .localOutput,
                uid: speakers.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 1,
                channelCount: 2
            )
        }
        XCTAssertEqual(local[0], 0, accuracy: 0.000_1)
        XCTAssertEqual(local[1], 0, accuracy: 0.000_1)
    }

    @MainActor
    func testViewFilterAndSearchDoNotDisableArmedControls() {
        let controller = armedController()
        let before = Set(controller.strips.map(\.id))
        controller.setGroupVisible(.applicationInputs, visible: false)
        XCTAssertEqual(controller.visibleMixerBanks.map(\.group), [.hardwareInputs, .localOutputs])
        XCTAssertEqual(Set(controller.strips.map(\.id)), before)
        let mixed = renderLocal(controller)
        XCTAssertEqual(mixed[0], 11.0, accuracy: 0.000_1)

        controller.trackManagerSearch = "no-such-source"
        XCTAssertTrue(controller.availableHardwareInputs.isEmpty)
        XCTAssertTrue(controller.availableApplicationInputs.isEmpty)
        XCTAssertEqual(Set(controller.strips.map(\.id)), before)
        XCTAssertEqual(renderLocal(controller)[0], 11.0, accuracy: 0.000_1)
    }

    @MainActor
    func testAddRemoveAndClearChangeWhatTheCycleHears() {
        let controller = MixerController()
        controller.devices = [mic, speakers]
        controller.inputSources = [micSource]
        controller.destinations = [speakerDest]
        XCTAssertTrue(controller.strips.isEmpty)

        controller.addInputToMixer(micSource)
        controller.addOutputToMixer(speakerDest)
        XCTAssertEqual(Set(controller.strips.map(\.uid)), [mic.uid, speakers.uid])
        XCTAssertEqual(renderLocal(controller, appFrames: [0, 0])[0], 1.0, accuracy: 0.000_1)

        controller.removeFromMixer(inputStrip(controller, uid: mic.uid))
        XCTAssertFalse(controller.strips.contains { $0.uid == mic.uid })
        XCTAssertEqual(renderLocal(controller, appFrames: [0, 0])[0], 0, accuracy: 0.000_1)

        controller.addInputToMixer(micSource)
        controller.clearMixer()
        XCTAssertTrue(controller.strips.isEmpty)
        XCTAssertEqual(renderLocal(controller, appFrames: [0, 0])[0], 0, accuracy: 0.000_1)
    }

    func testMixerViewBindsControlsToLiveStripState() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mixy/MixerView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("liveStrip"))
        XCTAssertTrue(text.contains("self.live.gainDecibels"))
        XCTAssertTrue(text.contains("self.live.pan"))
        XCTAssertTrue(text.contains("setMuted"))
        XCTAssertTrue(text.contains("setSoloed"))
        XCTAssertTrue(text.contains("setEnabled"))
        XCTAssertTrue(text.contains("setGain"))
        XCTAssertTrue(text.contains("setPan"))
        XCTAssertTrue(text.contains("VerticalFader"))
    }
}
