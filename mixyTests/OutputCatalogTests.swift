import CoreAudio
import XCTest
@testable import mixy

final class OutputCatalogTests: XCTestCase {
    private let speakers = DeviceRecord(
        uid: "BuiltInSpeakerDevice",
        name: "MacBook Air Speakers",
        manufacturer: "Apple Inc.",
        transportType: kAudioDeviceTransportTypeBuiltIn,
        inputChannelCount: 0,
        outputChannelCount: 2
    )
    private let scarlett = DeviceRecord(
        uid: "usb-scarlett",
        name: "Scarlett 18i20",
        manufacturer: "Focusrite",
        transportType: kAudioDeviceTransportTypeUSB,
        inputChannelCount: 18,
        outputChannelCount: 20
    )
    private let appleTV = DeviceRecord(
        uid: "hal-appletv",
        name: "Living Room",
        manufacturer: "Apple Inc.",
        transportType: kAudioDeviceTransportTypeAirPlay,
        inputChannelCount: 0,
        outputChannelCount: 2
    )
    private let hdmi = DeviceRecord(
        uid: "hdmi-out",
        name: "LG HDR 4K",
        transportType: kAudioDeviceTransportTypeHDMI,
        inputChannelCount: 0,
        outputChannelCount: 2
    )
    private let sessionHomePod = SessionAirPlayEndpoint(
        uid: SessionAirPlayEndpoint.uid(serviceType: "_airplay._tcp", name: "HomePod"),
        name: "HomePod",
        supportsVideo: true,
        serviceType: "_airplay._tcp"
    )
    private let sessionRAOP = SessionAirPlayEndpoint(
        uid: SessionAirPlayEndpoint.uid(serviceType: "_raop._tcp", name: "Kitchen"),
        name: "Kitchen",
        supportsVideo: false,
        serviceType: "_raop._tcp"
    )

    func testMergeListsSessionAirPlayAndHALOutputs() {
        let dests = OutputCatalog.merge(
            halDevices: [speakers, scarlett],
            sessionAirPlay: [sessionHomePod, sessionRAOP]
        )
        XCTAssertEqual(dests.count, 4)
        let home = dests.first { $0.name == "HomePod" }
        XCTAssertNotNil(home)
        XCTAssertTrue(home?.isAirPlay == true)
        XCTAssertEqual(home?.source, .sessionAirPlay)
        XCTAssertTrue(home?.supportsVideo == true)
        let kitchen = dests.first { $0.name == "Kitchen" }
        XCTAssertTrue(kitchen?.isAirPlay == true)
        XCTAssertFalse(kitchen?.supportsVideo == true)
        let local = dests.first { $0.uid == speakers.uid }
        XCTAssertNotNil(local)
        XCTAssertFalse(local?.isAirPlay ?? true)
        XCTAssertEqual(local?.kindLabel, "Built-in")
        XCTAssertTrue(OutputCatalog.otherOutputs(in: dests).contains { $0.uid == speakers.uid })
        XCTAssertTrue(OutputCatalog.airPlayDestinations(in: dests).contains { $0.name == "HomePod" })
    }

    func testMergeUnionsVideoWhenRAOPArrivesBeforeAirPlaySameName() {
        let raop = SessionAirPlayEndpoint(
            uid: SessionAirPlayEndpoint.uid(serviceType: "_raop._tcp", name: "HomePod"),
            name: "HomePod",
            supportsVideo: false,
            serviceType: "_raop._tcp"
        )
        let video = SessionAirPlayEndpoint(
            uid: SessionAirPlayEndpoint.uid(serviceType: "_airplay._tcp", name: "HomePod"),
            name: "HomePod",
            supportsVideo: true,
            serviceType: "_airplay._tcp"
        )
        let dests = OutputCatalog.merge(halDevices: [speakers], sessionAirPlay: [raop, video])
        let homes = dests.filter { $0.name == "HomePod" }
        XCTAssertEqual(homes.count, 1)
        XCTAssertTrue(homes[0].isAirPlay)
        XCTAssertTrue(homes[0].supportsVideo, "later _airplay._tcp must union video onto the RAOP row")

        let reverse = OutputCatalog.merge(halDevices: [speakers], sessionAirPlay: [video, raop])
        XCTAssertEqual(reverse.filter { $0.name == "HomePod" }.count, 1)
        XCTAssertTrue(reverse.first { $0.name == "HomePod" }?.supportsVideo == true)
    }

    func testShippedAppInfoPlistDeclaresAirPlayBonjourServices() {
        let services = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String]
        XCTAssertEqual(
            services.map { Set($0) },
            Set(["_airplay._tcp", "_raop._tcp"]),
            "mixy.app Info.plist must list AirPlay/RAOP Bonjour types; got \(String(describing: services))"
        )
    }

    func testMergeDeduplicatesHALAirPlayWithSessionSameName() {
        let dests = OutputCatalog.merge(
            halDevices: [appleTV],
            sessionAirPlay: [
                SessionAirPlayEndpoint(
                    uid: "airplay:_airplay._tcp:Living Room",
                    name: "Living Room",
                    supportsVideo: true,
                    serviceType: "_airplay._tcp"
                )
            ]
        )
        XCTAssertEqual(dests.count, 1)
        XCTAssertEqual(dests[0].source, .hal)
        XCTAssertTrue(dests[0].isAirPlay)
    }

    func testAudioSelectionIsolatesAirPlayAndKeepsLocalOnClock() {
        let dests = OutputCatalog.merge(
            halDevices: [speakers, scarlett],
            sessionAirPlay: [sessionHomePod]
        )
        let selected: Set<String> = [speakers.uid, sessionHomePod.uid, scarlett.uid]
        let graph = AudioVideoRouter.audioGraph(destinations: dests, selectedAudioUIDs: selected)
        XCTAssertTrue(graph.isolatedAirPlayUIDs.contains(sessionHomePod.uid))
        XCTAssertFalse(graph.localClockDeviceUIDs.contains(sessionHomePod.uid))
        XCTAssertTrue(graph.localClockDeviceUIDs.contains(speakers.uid))
        XCTAssertTrue(graph.localClockDeviceUIDs.contains(scarlett.uid))
        let airPlayRecord = dests.first { $0.uid == sessionHomePod.uid }?.asDeviceRecord
        XCTAssertEqual(airPlayRecord.map(DeviceClassifier.classify), .airPlay)
    }

    func testVideoSelectionUpdatesShippedRecord() {
        let dests = OutputCatalog.merge(
            halDevices: [speakers, hdmi],
            sessionAirPlay: [sessionHomePod]
        )
        XCTAssertFalse(dests.first { $0.uid == speakers.uid }?.supportsVideo ?? true)
        XCTAssertTrue(dests.first { $0.uid == hdmi.uid }?.supportsVideo == true)
        XCTAssertTrue(dests.first { $0.uid == sessionHomePod.uid }?.supportsVideo == true)

        var record = AudioVideoRouter.videoRecord(destinations: dests, selectedVideoUIDs: [])
        XCTAssertFalse(record.routes.contains { $0.uid == speakers.uid })
        XCTAssertEqual(record.selectedUIDs, [])
        let homeEntry = record.entry(uid: sessionHomePod.uid)
        XCTAssertEqual(homeEntry?.isAirPlay, true)
        XCTAssertEqual(homeEntry?.isSelected, false)

        let selected = AudioVideoRouter.applyingVideoSelection(
            destinations: dests,
            selectedVideoUIDs: [],
            toggling: sessionHomePod.uid,
            enabled: true
        )
        XCTAssertTrue(selected.record.entry(uid: sessionHomePod.uid)?.isSelected == true)
        XCTAssertTrue(selected.record.entry(uid: sessionHomePod.uid)?.isAirPlay == true)
        XCTAssertEqual(selected.record.selectedUIDs, [sessionHomePod.uid])

        let cleared = AudioVideoRouter.applyingVideoSelection(
            destinations: dests,
            selectedVideoUIDs: selected.selected,
            toggling: sessionHomePod.uid,
            enabled: false
        )
        XCTAssertFalse(cleared.record.entry(uid: sessionHomePod.uid)?.isSelected ?? true)
        XCTAssertTrue(cleared.record.selectedUIDs.isEmpty)

        let hdmiOn = AudioVideoRouter.applyingVideoSelection(
            destinations: dests,
            selectedVideoUIDs: [],
            toggling: hdmi.uid,
            enabled: true
        )
        XCTAssertTrue(hdmiOn.record.entry(uid: hdmi.uid)?.isSelected == true)
        XCTAssertFalse(hdmiOn.record.entry(uid: hdmi.uid)?.isAirPlay ?? true)
    }

    func testRAOPDisplayNameStripsMACPrefix() {
        XCTAssertEqual(
            SessionAirPlayBrowser.displayName(fromServiceName: "AABBCCDDEEFF@Living Room"),
            "Living Room"
        )
        XCTAssertEqual(SessionAirPlayBrowser.displayName(fromServiceName: "HomePod"), "HomePod")
    }

    func testRoutingPanelSourceBindsAudioAndVideoControls() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mixy/MixerView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("TrackManagerView") || source.contains("Add AirPlay") || source.contains("addSectionTitle(.airPlay)"))
        XCTAssertTrue(source.contains("addOutputToMixer") || source.contains("setAudioRoute"))
        XCTAssertTrue(source.contains("setVideoRoute"))
        XCTAssertTrue(source.contains("AirPlay"))
        XCTAssertTrue(source.contains("destination.isAirPlay") || source.contains("addSectionTitle(.airPlay)"))
    }
}
