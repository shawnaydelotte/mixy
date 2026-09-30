import CoreAudio
import XCTest
@testable import mixy

final class MixerDeskTests: XCTestCase {
    private let mic = InputSource(
        uid: "BuiltInMicrophoneDevice",
        name: "MacBook Air Microphone",
        kind: .hardware,
        inputChannelCount: 1,
        transportName: "Built-in"
    )
    private let music = InputSource(
        uid: "app:com.apple.Music:9",
        name: "Music",
        kind: .application,
        inputChannelCount: 2,
        transportName: "Application",
        isRunningOutput: true
    )
    private let idle = InputSource(
        uid: "app:com.apple.Notes:8",
        name: "Notes",
        kind: .application,
        inputChannelCount: 2,
        transportName: "Application",
        isRunningOutput: false
    )
    private let speakers = OutputDestination(
        uid: "BuiltInSpeakerDevice",
        name: "MacBook Air Speakers",
        source: .hal,
        transportType: kAudioDeviceTransportTypeBuiltIn,
        supportsAudio: true,
        supportsVideo: false,
        outputChannelCount: 2
    )
    private let appleTV = OutputDestination(
        uid: "airplay-living",
        name: "Living Room",
        source: .sessionAirPlay,
        transportType: kAudioDeviceTransportTypeAirPlay,
        supportsAudio: true,
        supportsVideo: true,
        outputChannelCount: 2
    )

    func testGroupsStripsIntoHardwareAppOutputAndAirPlayBanks() {
        let strips = [
            MixerStrip(uid: mic.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 0], isInput: true),
            MixerStrip(uid: music.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: true),
            MixerStrip(uid: speakers.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: false),
            MixerStrip(uid: appleTV.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: false)
        ]
        let banks = MixerDesk.banks(
            strips: strips,
            inputs: [mic, music],
            destinations: [speakers, appleTV]
        )
        XCTAssertEqual(banks.map(\.group), [
            .hardwareInputs, .applicationInputs, .localOutputs, .airPlay
        ])
        XCTAssertEqual(banks[0].strips.map(\.uid), [mic.uid])
        XCTAssertEqual(banks[1].strips.map(\.uid), [music.uid])
        XCTAssertEqual(banks[2].strips.map(\.uid), [speakers.uid])
        XCTAssertEqual(banks[3].strips.map(\.uid), [appleTV.uid])
    }

    func testAvailableCatalogOmitsChannelsAlreadyOnTheDesk() {
        let inMixer: Set<String> = [mic.uid, speakers.uid]
        let inputs = MixerDesk.availableInputs(
            catalog: [mic, music, idle],
            inMixer: inMixer,
            playingOnly: false
        )
        XCTAssertFalse(inputs.contains { $0.uid == mic.uid })
        XCTAssertTrue(inputs.contains { $0.uid == music.uid })
        XCTAssertTrue(inputs.contains { $0.uid == idle.uid })

        let playing = MixerDesk.availableInputs(
            catalog: [mic, music, idle],
            inMixer: [],
            playingOnly: true
        )
        XCTAssertTrue(playing.contains { $0.uid == music.uid })
        XCTAssertFalse(playing.contains { $0.uid == idle.uid })
        XCTAssertTrue(playing.contains { $0.uid == mic.uid })

        let outs = MixerDesk.availableOutputs(
            catalog: [speakers, appleTV],
            inMixer: inMixer,
            airPlayOnly: false
        )
        XCTAssertFalse(outs.contains { $0.uid == speakers.uid })
        let air = MixerDesk.availableOutputs(
            catalog: [speakers, appleTV],
            inMixer: inMixer,
            airPlayOnly: true
        )
        XCTAssertEqual(air.map(\.uid), [appleTV.uid])
    }

    @MainActor
    func testAddingToMixerDoesNotDumpEntireCatalogOntoDesk() {
        let controller = MixerController()
        controller.inputSources = [mic, music, idle]
        controller.destinations = [speakers, appleTV]
        XCTAssertTrue(controller.strips.isEmpty)
        controller.addInputToMixer(mic)
        controller.addOutputToMixer(speakers)
        XCTAssertEqual(Set(controller.strips.map(\.uid)), [mic.uid, speakers.uid])
        XCTAssertTrue(controller.availableApplicationInputs.contains { $0.uid == music.uid })
        XCTAssertTrue(controller.availableAirPlayOutputs.contains { $0.uid == appleTV.uid })
        controller.removeFromMixer(controller.strips.first { $0.uid == mic.uid }!)
        XCTAssertFalse(controller.strips.contains { $0.uid == mic.uid })
        XCTAssertTrue(controller.availableHardwareInputs.contains { $0.uid == mic.uid })
    }

    func testMixerViewUsesTrackManagerAndAddMenus() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mixy/MixerView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("TrackManagerView"))
        XCTAssertTrue(text.contains("AddChannelMenus"))
        XCTAssertTrue(text.contains("addSectionTitle(.hardwareInputs)"))
        XCTAssertTrue(text.contains("addSectionTitle(.applicationInputs)"))
        XCTAssertTrue(text.contains("addSectionTitle(.airPlay)"))
        XCTAssertTrue(text.contains("addInputToMixer"))
        XCTAssertTrue(text.contains("addOutputToMixer"))
        XCTAssertTrue(text.contains("Remove from Mixer"))
        XCTAssertTrue(text.contains("StripIOAssignmentMenu"))
        XCTAssertTrue(text.contains("MixerViewFilterBar"))
        XCTAssertTrue(text.contains("onMixerSectionTitle"))
        XCTAssertTrue(text.contains("reassignInput"))
        XCTAssertTrue(text.contains("reassignOutput"))
    }

    func testViewFilterHidesBanksWithoutRemovingStrips() {
        let strips = [
            MixerStrip(uid: mic.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 0], isInput: true),
            MixerStrip(uid: speakers.uid, isEnabled: true, gainDecibels: 0, channelMap: [0, 1], isInput: false)
        ]
        let all = MixerDesk.banks(strips: strips, inputs: [mic], destinations: [speakers])
        let filtered = MixerDesk.banks(all, visibleGroups: [.hardwareInputs])
        XCTAssertEqual(filtered.map(\.group), [.hardwareInputs])
        XCTAssertEqual(all.count, 2)
    }

    @MainActor
    func testReassignTransfersFaderMuteSoloPan() {
        let existing = MixerStrip(
            uid: mic.uid,
            isEnabled: true,
            gainDecibels: -6,
            channelMap: [0, 0],
            isInput: true,
            isMuted: true,
            isSoloed: true,
            pan: -0.5
        )
        let next = InputRouter.inputStrip(for: music, enabled: true, existing: nil)
        let transferred = MixerDesk.transferringControls(from: existing, onto: next)
        XCTAssertEqual(transferred.uid, music.uid)
        XCTAssertEqual(transferred.gainDecibels, -6)
        XCTAssertTrue(transferred.isMuted)
        XCTAssertTrue(transferred.isSoloed)
        XCTAssertEqual(transferred.pan, -0.5)

        let controller = MixerController()
        controller.inputSources = [mic, music]
        controller.destinations = [speakers, appleTV]
        controller.addInputToMixer(mic)
        controller.setGain(controller.strips[0], decibels: -9)
        controller.setMuted(controller.strips[0], muted: true)
        controller.reassignInput(controller.strips[0], to: music)
        XCTAssertEqual(controller.strips.count, 1)
        XCTAssertEqual(controller.strips[0].uid, music.uid)
        XCTAssertEqual(controller.strips[0].gainDecibels, -9)
        XCTAssertTrue(controller.strips[0].isMuted)
        XCTAssertTrue(controller.availableHardwareInputs.contains { $0.uid == mic.uid })
        XCTAssertFalse(controller.availableApplicationInputs.contains { $0.uid == music.uid })
    }

    @MainActor
    func testClearMixerDoesNotReseedBuiltInDesk() {
        let controller = MixerController()
        controller.inputSources = [mic]
        controller.destinations = [speakers]
        controller.addInputToMixer(mic)
        controller.clearMixer()
        XCTAssertTrue(controller.strips.isEmpty)
        controller.applyDevices([])
        XCTAssertTrue(controller.strips.isEmpty)
    }
}
