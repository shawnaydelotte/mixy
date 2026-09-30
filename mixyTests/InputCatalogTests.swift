import AudioToolbox
import CoreAudio
import XCTest
@testable import mixy

final class InputCatalogTests: XCTestCase {
    private let mic = DeviceRecord(
        uid: "BuiltInMicrophoneDevice",
        name: "MacBook Air Microphone",
        manufacturer: "Apple Inc.",
        transportType: kAudioDeviceTransportTypeBuiltIn,
        inputChannelCount: 1,
        outputChannelCount: 0
    )
    private let interface = DeviceRecord(
        uid: "usb-scarlett",
        name: "Scarlett 18i20",
        manufacturer: "Focusrite",
        transportType: kAudioDeviceTransportTypeUSB,
        inputChannelCount: 18,
        outputChannelCount: 20
    )
    private let speakers = DeviceRecord(
        uid: "BuiltInSpeakerDevice",
        name: "MacBook Air Speakers",
        transportType: kAudioDeviceTransportTypeBuiltIn,
        inputChannelCount: 0,
        outputChannelCount: 2
    )
    private let music = AppAudioProcess(
        objectID: 42,
        pid: 4242,
        bundleID: "com.apple.Music",
        name: "Music",
        isRunningOutput: true
    )

    func testCatalogListsEveryHardwareInputNotOnlyDefault() {
        let sources = InputCatalog.merge(halDevices: [mic, interface, speakers], processes: [])
        let hardware = InputCatalog.hardwareInputs(in: sources)
        XCTAssertEqual(Set(hardware.map(\.uid)), [mic.uid, interface.uid])
        XCTAssertFalse(hardware.contains { $0.uid == speakers.uid })
        let micSource = hardware.first { $0.uid == mic.uid }
        XCTAssertEqual(micSource?.inputChannelCount, 1)
        XCTAssertTrue(micSource?.isHardware == true)
        XCTAssertEqual(micSource?.transportName, "Built-in")
        let iface = hardware.first { $0.uid == interface.uid }
        XCTAssertEqual(iface?.inputChannelCount, 18)
        XCTAssertFalse(iface?.isApplicationAudio ?? true)
    }

    func testAppAudioRecordIsInputNotOutputOrAirPlay() {
        let sources = InputCatalog.merge(halDevices: [mic, speakers], processes: [music])
        let app = sources.first { $0.uid == music.uid }
        XCTAssertNotNil(app)
        XCTAssertTrue(app?.isApplicationAudio == true)
        XCTAssertFalse(app?.isHardware ?? true)
        XCTAssertEqual(app?.kind, .application)
        XCTAssertTrue(sources.contains { $0.uid == InputSource.systemWideUID })

        let selected: Set<String> = [mic.uid, music.uid]
        let graph = InputRouter.graph(inputs: sources, selectedUIDs: selected)
        XCTAssertEqual(graph.hardwareInputUIDs, [mic.uid])
        XCTAssertEqual(graph.applicationInputUIDs, [music.uid])

        let dests = OutputCatalog.merge(halDevices: [speakers], sessionAirPlay: [])
        let mixGraph = AudioVideoRouter.audioGraph(destinations: dests, selectedAudioUIDs: [speakers.uid])
        XCTAssertFalse(InputRouter.isTreatedAsOutput(uid: music.uid, mixGraph: mixGraph))
        XCTAssertFalse(mixGraph.isolatedAirPlayUIDs.contains(music.uid))
        XCTAssertFalse(mixGraph.localClockDeviceUIDs.contains(music.uid))
    }

    func testHardwarePlusAppCapturesSumInShippedIOCycle() {
        let appUID = music.uid
        let strips = [
            MixerStrip(
                uid: mic.uid,
                isEnabled: true,
                gainDecibels: AmplitudeGain.decibels(fromLinear: 0.5),
                channelMap: [0, 0],
                isInput: true
            ),
            MixerStrip(
                uid: appUID,
                isEnabled: true,
                gainDecibels: AmplitudeGain.decibels(fromLinear: 2.0),
                channelMap: [0, 1],
                isInput: true
            ),
            MixerStrip(uid: speakers.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: false)
        ]
        var feeds: [String: AirPlaySafeBuffer] = [:]
        let graph = MixGraph(
            localClockDeviceUIDs: [speakers.uid],
            isolatedAirPlayUIDs: [],
            bufferFramesLocal: 512,
            bufferFramesAirPlay: 4096,
            extraLatencyFramesAirPlay: 4096
        )
        let result = MixIOCycle.run(
            captures: [
                mic.uid: PCMBuffer(samples: [1.0], channelCount: 1),
                appUID: PCMBuffer(samples: [10.0, 20.0], channelCount: 2)
            ],
            strips: strips,
            devices: [mic, speakers],
            graph: graph,
            airPlayFeeds: &feeds,
            frameCount: 1,
            mixChannelCount: 2
        )
        XCTAssertEqual(result.mixed[frame: 0, channel: 0], 1.0 * 0.5 + 10.0 * 2.0, accuracy: 0.000_1)
        XCTAssertEqual(result.mixed[frame: 0, channel: 1], 1.0 * 0.5 + 20.0 * 2.0, accuracy: 0.000_1)
        XCTAssertNotNil(result.localOutputs[speakers.uid])
        XCTAssertNil(result.localOutputs[appUID])
        XCTAssertTrue(result.airPlayOutputs.isEmpty)
    }

    func testHandleHardwareIOMixesAppCaptureAsInput() {
        let io = AudioIOCoordinator()
        let appUID = music.uid
        io.update(
            devices: [mic, speakers],
            strips: [
                MixerStrip(uid: mic.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 0], isInput: true),
                MixerStrip(uid: appUID, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: true),
                MixerStrip(uid: speakers.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: false)
            ],
            inputs: InputCatalog.merge(halDevices: [mic, speakers], processes: [music])
        )
        var hw: [Float] = [0.25]
        var app: [Float] = [0.5, 0.75]
        hw.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(role: .input, uid: mic.uid, interleavedFrames: pointer.baseAddress!, frameCount: 1, channelCount: 1)
        }
        app.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(role: .input, uid: appUID, interleavedFrames: pointer.baseAddress!, frameCount: 1, channelCount: 2)
        }
        var local = [Float](repeating: -1, count: 2)
        local.withUnsafeMutableBufferPointer { pointer in
            io.handleHardwareIO(role: .localOutput, uid: speakers.uid, interleavedFrames: pointer.baseAddress!, frameCount: 1, channelCount: 2)
        }
        XCTAssertEqual(local[0], 0.25 + 0.5, accuracy: 0.000_1)
        XCTAssertEqual(local[1], 0.25 + 0.75, accuracy: 0.000_1)
    }

    func testAttachInputUnitUsesProvidedDeviceIDNotUIDLookup() throws {
        let fakePrivateUID = "mixy.tap.app:system-wide"
        XCTAssertNil(
            HALDeviceEnumerator.audioObjectID(forUID: fakePrivateUID),
            "private tap aggregates are not listed in kAudioHardwarePropertyDevices"
        )

        let liveID = HALDeviceEnumerator.audioObjectID(forUID: "BuiltInSpeakerDevice")
            ?? HALDeviceEnumerator.audioObjectID(forUID: speakers.uid)
            ?? HALDeviceEnumerator.audioObjectID(forUID: mic.uid)
        guard let liveID else {
            throw XCTSkip("no live HAL device ID to stand in for a tap aggregate")
        }

        let session = ProcessTapSession(
            tapID: 0,
            tapUID: "tap-uid",
            aggregateUID: fakePrivateUID,
            aggregateDeviceID: liveID,
            sourceUID: "app:com.apple.Music:99"
        )
        XCTAssertEqual(ProcessTapAdapter.inputDeviceID(for: session), liveID)
        XCTAssertNotEqual(ProcessTapAdapter.inputDeviceID(for: session), kAudioObjectUnknown)

        let io = AudioIOCoordinator()
        let captureUID = session.sourceUID
        let context = try io.attachInputUnit(
            deviceID: ProcessTapAdapter.inputDeviceID(for: session),
            captureUID: captureUID,
            channelCount: 2,
            bufferFrames: 512,
            initialize: false
        )
        guard let context else {
            XCTFail("attachInputUnit must open AUHAL on the provided deviceID")
            return
        }
        defer {
            if let unit = context.unit {
                AudioComponentInstanceDispose(unit)
            }
        }
        XCTAssertEqual(context.uid, captureUID)
        XCTAssertEqual(context.role, .input)
        guard let unit = context.unit else {
            XCTFail("attached unit missing")
            return
        }
        var bound = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &bound,
            &size
        )
        XCTAssertEqual(status, noErr)
        XCTAssertEqual(bound, liveID, "AUHAL must be bound to the tap aggregate deviceID, not a UID lookup")
    }

    func testProcessTapAdapterSourceIsFirstParty() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mixy/HAL/ProcessTapAdapter.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("AudioHardwareCreateProcessTap"))
        XCTAssertTrue(source.contains("CATapDescription"))
        XCTAssertTrue(source.contains("kAudioAggregateDeviceTapListKey"))
        XCTAssertTrue(source.contains("AudioHardwareCreateAggregateDevice"))
        let desc = ProcessTapAdapter.description(for: .systemWideTap)
        XCTAssertTrue(desc.isExclusive || desc.name.contains("Application"))
    }

    func testInputPanelSourceListsHardwareAndApps() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mixy/MixerView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("TrackManagerView") || text.contains("track-manager"))
        XCTAssertTrue(text.contains("addInputToMixer"))
        XCTAssertTrue(text.contains("isApplicationAudio"))
        XCTAssertTrue(text.contains("HARDWARE") || text.contains("Hardware Inputs") || text.contains("addSectionTitle(.hardwareInputs)"))
        XCTAssertTrue(text.contains("Add Hardware Input") || text.contains("AddChannelMenus"))
    }
}
