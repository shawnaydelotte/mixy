import CoreAudio
import XCTest
@testable import mixy

final class MixerChromeTests: XCTestCase {
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

    func testMuteSoloEnabledChromeAreDistinctWhenLit() {
        let muteOn = MixerChrome.muteChrome(isMuted: true)
        let muteOff = MixerChrome.muteChrome(isMuted: false)
        let soloOn = MixerChrome.soloChrome(isSoloed: true)
        let soloOff = MixerChrome.soloChrome(isSoloed: false)
        let on = MixerChrome.enabledChrome(isEnabled: true)
        let off = MixerChrome.enabledChrome(isEnabled: false)

        XCTAssertEqual(muteOn.label, "M")
        XCTAssertEqual(soloOn.label, "S")
        XCTAssertEqual(on.label, "ON")
        XCTAssertEqual(off.label, "OFF")
        XCTAssertTrue(muteOn.isLit)
        XCTAssertFalse(muteOff.isLit)
        XCTAssertTrue(soloOn.isLit)
        XCTAssertFalse(soloOff.isLit)
        XCTAssertTrue(on.isLit)
        XCTAssertFalse(off.isLit)

        XCTAssertNotEqual(muteOn.fill, muteOff.fill)
        XCTAssertNotEqual(soloOn.fill, soloOff.fill)
        XCTAssertNotEqual(on.fill, off.fill)
        XCTAssertNotEqual(muteOn.fill, soloOn.fill)
        XCTAssertNotEqual(muteOn.fill, on.fill)
        XCTAssertNotEqual(soloOn.fill, on.fill)
        XCTAssertEqual(muteOff.fill, MixerColorToken.padOff)
        XCTAssertEqual(soloOff.fill, MixerColorToken.padOff)
    }

    func testGainAndPanLabels() {
        XCTAssertEqual(MixerChrome.panLabel(0), "C")
        XCTAssertEqual(MixerChrome.panLabel(0.01), "C")
        XCTAssertEqual(MixerChrome.panLabel(-0.5), "L50")
        XCTAssertEqual(MixerChrome.panLabel(1), "R100")
        XCTAssertEqual(MixerChrome.gainLabel(0), "+0.0 dB")
        XCTAssertEqual(MixerChrome.gainLabel(-6), "-6.0 dB")
        XCTAssertEqual(MixerChrome.gainLabel(12), "+12.0 dB")
        XCTAssertNotEqual(MixerChrome.gainLabel(-6), MixerChrome.gainLabel(0))
        XCTAssertNotEqual(MixerChrome.panLabel(-0.5), MixerChrome.panLabel(0.5))
    }

    func testGroupTitlesAndKindBadgesAreDistinct() {
        XCTAssertEqual(MixerChrome.bankTitle(.hardwareInputs), "HARDWARE INPUTS")
        XCTAssertEqual(MixerChrome.onMixerSectionTitle(.applicationInputs), "On Mixer — Application Audio")
        XCTAssertEqual(MixerChrome.addSectionTitle(.airPlay), "Add AirPlay Destination")
        XCTAssertEqual(MixerChrome.roleLabel(isInput: true), "IN")
        XCTAssertEqual(MixerChrome.roleLabel(isInput: false), "OUT")
        XCTAssertEqual(MixerChrome.kindBadgeLabel(.airPlay), "AP")
        XCTAssertEqual(MixerChrome.kindBadgeLabel(.local), "LOCAL")
        XCTAssertEqual(MixerChrome.kindBadgeLabel(.musicInterface), "MUSIC")
        XCTAssertEqual(MixerChrome.kindBadgeLabel(.virtual), "VIRT")
        XCTAssertNotEqual(MixerChrome.groupAccent(.hardwareInputs), MixerChrome.groupAccent(.airPlay))
        XCTAssertNotEqual(MixerChrome.kindToken(.airPlay), MixerChrome.kindToken(.virtual))
        XCTAssertEqual(MixerChrome.applicationBadgeLabel(kind: .application), "APP")
        XCTAssertEqual(MixerChrome.applicationBadgeLabel(kind: .systemWideAppTap), "ALL APPS")
        XCTAssertNil(MixerChrome.applicationBadgeLabel(kind: .hardware))
        XCTAssertEqual(MixerChrome.channelCountLabel(2), "2 ch")
    }

    func testStripOpacityAndDeskCopy() {
        XCTAssertEqual(MixerChrome.stripOpacity(isMuted: false, isEnabled: true), 1.0)
        XCTAssertEqual(MixerChrome.stripOpacity(isMuted: true, isEnabled: true), 0.62)
        XCTAssertEqual(MixerChrome.stripOpacity(isMuted: false, isEnabled: false), 0.55)
        XCTAssertEqual(MixerChrome.stripOpacity(isMuted: true, isEnabled: false), 0.48)
        let empty = MixerChrome.emptyDeskCopy()
        let hidden = MixerChrome.hiddenGroupsCopy()
        XCTAssertEqual(empty.title, "Empty mixer")
        XCTAssertEqual(hidden.title, "All groups hidden")
        XCTAssertNotEqual(empty.title, hidden.title)
        XCTAssertNotEqual(empty.systemImage, hidden.systemImage)
        XCTAssertFalse(MixerChrome.emptyCatalogCopy().isEmpty)
        XCTAssertEqual(MixerChrome.faderNormalized(value: -96, range: -96...12), 0, accuracy: 0.000_1)
        XCTAssertEqual(MixerChrome.faderNormalized(value: 12, range: -96...12), 1, accuracy: 0.000_1)
        XCTAssertTrue(MixerChrome.faderTickDecibels.contains(0))
    }

    @MainActor
    func testAddingTwoSourcesDoesNotDumpCatalogAndViewFilterKeepsStrips() {
        let controller = MixerController()
        controller.inputSources = [mic, music, idle]
        controller.destinations = [speakers, appleTV]
        controller.addInputToMixer(mic)
        controller.addOutputToMixer(speakers)
        XCTAssertEqual(Set(controller.strips.map(\.uid)), [mic.uid, speakers.uid])
        XCTAssertTrue(controller.availableApplicationInputs.contains { $0.uid == music.uid })
        XCTAssertTrue(controller.availableApplicationInputs.contains { $0.uid == idle.uid })
        XCTAssertTrue(controller.availableAirPlayOutputs.contains { $0.uid == appleTV.uid })

        let before = controller.strips
        controller.setGroupVisible(.localOutputs, visible: false)
        let visible = MixerDesk.banks(controller.mixerBanks, visibleGroups: controller.visibleGroups)
        XCTAssertEqual(visible.map(\.group), [.hardwareInputs])
        XCTAssertEqual(controller.strips.map(\.uid), before.map(\.uid))
        XCTAssertTrue(controller.strips.contains { $0.uid == speakers.uid })
    }

    func testMixerViewConsumesShippedChrome() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mixy/MixerView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("MixerChrome.muteChrome"))
        XCTAssertTrue(text.contains("MixerChrome.soloChrome"))
        XCTAssertTrue(text.contains("MixerChrome.enabledChrome"))
        XCTAssertTrue(text.contains("MixerChrome.panLabel"))
        XCTAssertTrue(text.contains("MixerChrome.gainLabel"))
        XCTAssertTrue(text.contains("MixerChrome.emptyDeskCopy"))
        XCTAssertTrue(text.contains("MixerChrome.hiddenGroupsCopy"))
        XCTAssertTrue(text.contains("ChannelStripView"))
        XCTAssertTrue(text.contains("TrackManagerView"))
        XCTAssertTrue(text.contains("VerticalFader"))
        XCTAssertFalse(text.contains("Hello, world!"))
    }
}
