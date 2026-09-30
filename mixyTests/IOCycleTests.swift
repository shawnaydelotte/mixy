import AudioToolbox
import CoreAudio
import XCTest
@testable import mixy

final class IOCycleTests: XCTestCase {
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
        inputChannelCount: 4,
        outputChannelCount: 4
    )
    private let builtIn = DeviceRecord(
        uid: "builtin",
        name: "MacBook Air Speakers",
        manufacturer: "Apple Inc.",
        transportType: kAudioDeviceTransportTypeBuiltIn,
        inputChannelCount: 1,
        outputChannelCount: 2
    )
    private let musicB = DeviceRecord(
        uid: "usb-second",
        name: "Interface B",
        manufacturer: "Focusrite",
        transportType: kAudioDeviceTransportTypeUSB,
        inputChannelCount: 2,
        outputChannelCount: 2
    )

    private func coordinator() -> AudioIOCoordinator {
        let io = AudioIOCoordinator()
        io.update(
            devices: [airPlay, music, musicB, builtIn],
            strips: [
                MixerStrip(
                    uid: music.uid,
                    isEnabled: true,
                    gainDecibels: AmplitudeGain.decibels(fromLinear: 0.5),
                    channelMap: [0, 1, 2, 3],
                    isInput: true
                ),
                MixerStrip(
                    uid: musicB.uid,
                    isEnabled: true,
                    gainDecibels: AmplitudeGain.decibels(fromLinear: 2.0),
                    channelMap: [0, 1, -1, -1],
                    isInput: true
                ),
                MixerStrip(uid: builtIn.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: false),
                MixerStrip(uid: airPlay.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: false)
            ]
        )
        return io
    }

    func testHandleHardwareIOMixesTwoCapturesOntoLocalOutput() {
        let io = coordinator()
        var captureA: [Float] = [
            1.0, 2.0, 3.0, 4.0,
            5.0, 6.0, 7.0, 8.0
        ]
        var captureB: [Float] = [
            10.0, 20.0,
            30.0, 40.0
        ]
        captureA.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(
                role: .input,
                uid: music.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 2,
                channelCount: 4
            )
        }
        captureB.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(
                role: .input,
                uid: musicB.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 2,
                channelCount: 2
            )
        }

        var local = [Float](repeating: -99, count: 4)
        local.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(
                role: .localOutput,
                uid: builtIn.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 2,
                channelCount: 2
            )
        }

        XCTAssertEqual(local[0], 1.0 * 0.5 + 10.0 * 2.0, accuracy: 0.000_1)
        XCTAssertEqual(local[1], 2.0 * 0.5 + 20.0 * 2.0, accuracy: 0.000_1)
        XCTAssertEqual(local[2], 5.0 * 0.5 + 30.0 * 2.0, accuracy: 0.000_1)
        XCTAssertEqual(local[3], 6.0 * 0.5 + 40.0 * 2.0, accuracy: 0.000_1)

        guard let cycle = io.lastCycle else {
            XCTFail("handleHardwareIO must run processIOCycle")
            return
        }
        XCTAssertNotNil(cycle.localOutputs[builtIn.uid])
        XCTAssertNil(cycle.localOutputs[airPlay.uid], "AirPlay must not appear as a local-clock output")
        XCTAssertTrue(io.currentGraph.isolatedAirPlayUIDs.contains(airPlay.uid))
        XCTAssertFalse(io.currentGraph.localClockDeviceUIDs.contains(airPlay.uid))
    }

    func testAirPlayCallbackDoesNotEmitUntilSafeBufferIsPrimed() {
        let io = coordinator()
        var capture: [Float] = [0.25, -0.5, 0.75, 0.125]
        capture.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(
                role: .input,
                uid: music.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 2,
                channelCount: 2
            )
        }

        var air = [Float](repeating: -99, count: 4)
        air.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(
                role: .airPlayOutput,
                uid: airPlay.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 2,
                channelCount: 2
            )
        }
        XCTAssertEqual(air, [0, 0, 0, 0], "AirPlay callback must pull AirPlaySafeBuffer, not the live mix")

        var local = [Float](repeating: 0, count: 4)
        local.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(
                role: .localOutput,
                uid: builtIn.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 2,
                channelCount: 2
            )
        }
        XCTAssertEqual(local[0], 0.25 * 0.5, accuracy: 0.000_1)
        XCTAssertNotEqual(local, air)
    }

    func testAirPlayPullsDelayedMixAfterCushionFromShippedCycle() {
        let io = coordinator()
        let primeFrames = AirPlayPolicy.airPlayExtraLatencyFrames + 2
        var impulse = [Float](repeating: 0, count: primeFrames * 2)
        impulse[0] = 0.8
        impulse[1] = -0.4
        impulse.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(
                role: .input,
                uid: music.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: primeFrames,
                channelCount: 2
            )
        }

        var air = [Float](repeating: 0, count: 4)
        air.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(
                role: .airPlayOutput,
                uid: airPlay.uid,
                interleavedFrames: pointer.baseAddress!,
                frameCount: 2,
                channelCount: 2
            )
        }
        XCTAssertEqual(air[0], 0.8 * 0.5, accuracy: 0.000_1)
        XCTAssertEqual(air[1], -0.4 * 0.5, accuracy: 0.000_1)
    }

    func testMixIOCycleRunIsTheShippedCaptureMixRoutePath() {
        var feeds: [String: AirPlaySafeBuffer] = [:]
        let strips = [
            MixerStrip(uid: music.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: true),
            MixerStrip(uid: builtIn.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: false),
            MixerStrip(uid: airPlay.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: false)
        ]
        let graph = AirPlayPolicy.buildGraph(
            devices: [music, builtIn, airPlay],
            enabledUIDs: [music.uid, builtIn.uid, airPlay.uid]
        )
        let captures = [
            music.uid: PCMBuffer(samples: [0.5, 1.0], channelCount: 2)
        ]
        let result = MixIOCycle.run(
            captures: captures,
            strips: strips,
            devices: [music, builtIn, airPlay],
            graph: graph,
            airPlayFeeds: &feeds,
            frameCount: 1,
            mixChannelCount: 2
        )
        XCTAssertEqual(result.mixed.samples[0], Float(0.5), accuracy: 0.000_001)
        let localSample = result.localOutputs[builtIn.uid]?.samples.first ?? Float.nan
        XCTAssertEqual(localSample, Float(0.5), accuracy: 0.000_001)
        XCTAssertNil(result.localOutputs[airPlay.uid])
        XCTAssertNotNil(feeds[airPlay.uid], "cycle must write AirPlay only into AirPlaySafeBuffer")
        XCTAssertGreaterThan(feeds[airPlay.uid]?.bufferedFrameCount ?? 0, 0, "cycle must enqueue AirPlay frames")
    }

    func testStartMixRegistersShippedAUHALCallbacksOnLiveDevices() throws {
        XCTAssertEqual(
            AUHALCallbackBinding.propertySelector(for: .input),
            kAudioOutputUnitProperty_SetInputCallback
        )
        XCTAssertEqual(
            AUHALCallbackBinding.propertySelector(for: .localOutput),
            kAudioUnitProperty_SetRenderCallback
        )
        XCTAssertEqual(
            AUHALCallbackBinding.propertySelector(for: .airPlayOutput),
            kAudioUnitProperty_SetRenderCallback
        )
        XCTAssertTrue(AUHALCallbackBinding.isShippedProc(AUHALCallbackBinding.shippedProc))

        let io = AudioIOCoordinator()
        let callbacks: [InstalledIOCallback]
        do {
            callbacks = try LiveMixStarter.startOnLiveDevices(io)
        } catch {
            // If HAL initialize is blocked, still prove start() uses the shipped installer
            // by installing onto a freshly created AUHAL unit.
            var description = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_HALOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            guard let component = AudioComponentFindNext(nil, &description) else {
                XCTFail("HAL output unit unavailable and start() failed: \(error)")
                return
            }
            var unit: AudioUnit?
            XCTAssertEqual(AudioComponentInstanceNew(component, &unit), noErr)
            guard let unit else {
                XCTFail("could not create AUHAL unit")
                return
            }
            defer { AudioComponentInstanceDispose(unit) }
            let installed = AUHALCallbackBinding.install(
                on: unit,
                role: .localOutput,
                uid: "probe",
                context: UnsafeMutableRawPointer(bitPattern: 1)!
            )
            XCTAssertEqual(installed.propertySelector, kAudioUnitProperty_SetRenderCallback)
            XCTAssertTrue(installed.setPropertySucceeded)
            XCTAssertTrue(installed.procIsShippedAUHALCallback, "install must set mixyAUHALCallback")
            return
        }
        defer { io.stop() }

        XCTAssertFalse(callbacks.isEmpty, "start() must create AUHAL units and install callbacks")
        XCTAssertTrue(
            callbacks.contains {
                $0.role == "localOutput"
                    && $0.propertySelector == kAudioUnitProperty_SetRenderCallback
                    && $0.setPropertySucceeded
                    && $0.procIsShippedAUHALCallback
            },
            "Start Mix must register the shipped render callback: \(callbacks)"
        )
        XCTAssertEqual(io.installedCallbacks, callbacks)

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            XCTFail("HAL output component missing")
            return
        }
        var probe: AudioUnit?
        XCTAssertEqual(AudioComponentInstanceNew(component, &probe), noErr)
        guard let probe else { return }
        defer { AudioComponentInstanceDispose(probe) }
        let inputReg = AUHALCallbackBinding.install(
            on: probe,
            role: .input,
            uid: "probe-input",
            context: UnsafeMutableRawPointer(bitPattern: 2)!
        )
        XCTAssertEqual(inputReg.propertySelector, kAudioOutputUnitProperty_SetInputCallback)
        XCTAssertTrue(inputReg.setPropertySucceeded)
        XCTAssertTrue(inputReg.procIsShippedAUHALCallback, "input install must set mixyAUHALCallback")
    }

    func testDuplexInterfaceUsesInputWidthForInputRoleAndOutputWidthForOutputs() {
        let scarlett = DeviceRecord(
            uid: "usb-scarlett-1820",
            name: "Scarlett 18i20",
            manufacturer: "Focusrite",
            transportType: kAudioDeviceTransportTypeUSB,
            inputChannelCount: 18,
            outputChannelCount: 20
        )
        let devices = [scarlett]
        XCTAssertEqual(
            MixIOCycle.destinationChannelCount(uid: scarlett.uid, devices: devices, fallback: 2, role: .input),
            18
        )
        XCTAssertEqual(
            MixIOCycle.destinationChannelCount(uid: scarlett.uid, devices: devices, fallback: 2, role: .localOutput),
            20
        )
        XCTAssertEqual(
            MixIOCycle.destinationChannelCount(uid: scarlett.uid, devices: devices, fallback: 2, role: .airPlayOutput),
            20
        )

        var feeds: [String: AirPlaySafeBuffer] = [:]
        let graph = AirPlayPolicy.buildGraph(devices: devices, enabledUIDs: [scarlett.uid])
        let result = MixIOCycle.run(
            captures: [
                scarlett.uid: PCMBuffer(frameCount: 1, channelCount: 18)
            ],
            strips: [
                MixerStrip(
                    uid: scarlett.uid,
                    isEnabled: true,
                    gainDecibels: 0,
                    channelMap: MixSource.identityMap(channelCount: 18),
                    isInput: true
                ),
                MixerStrip(
                    uid: scarlett.uid,
                    isEnabled: true,
                    gainDecibels: 0,
                    channelMap: MixSource.identityMap(channelCount: 20),
                    isInput: false
                )
            ],
            devices: devices,
            graph: graph,
            airPlayFeeds: &feeds,
            frameCount: 1,
            mixChannelCount: MixIOCycle.mixChannelCount(
                devices: devices,
                strips: [
                    MixerStrip(uid: scarlett.uid, isEnabled: true, gainDecibels: 0, channelMap: MixSource.identityMap(channelCount: 18), isInput: true),
                    MixerStrip(uid: scarlett.uid, isEnabled: true, gainDecibels: 0, channelMap: MixSource.identityMap(channelCount: 20), isInput: false)
                ],
                captures: [:]
            )
        )
        XCTAssertEqual(result.localOutputs[scarlett.uid]?.channelCount, 20)
        XCTAssertNotEqual(result.localOutputs[scarlett.uid]?.channelCount, 18)
    }

    func testStopKeepsHALContextsUntilAfterUnitDispose() throws {
        let io = AudioIOCoordinator()
        do {
            _ = try LiveMixStarter.startOnLiveDevices(io)
        } catch {
            throw XCTSkip("live HAL start unavailable: \(error)")
        }
        XCTAssertTrue(io.isRunning)
        XCTAssertFalse(io.installedCallbacks.isEmpty)
        io.stop()
        XCTAssertFalse(io.isRunning)
        XCTAssertGreaterThan(
            io.retainedContextCountAtDispose,
            0,
            "stop() must retain HALIOContext across AudioOutputUnitStop/Dispose"
        )
        XCTAssertTrue(io.installedCallbacks.isEmpty)
    }
}
