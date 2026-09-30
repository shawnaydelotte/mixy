import CoreAudio
import XCTest
@testable import mixy

final class DeviceClassificationTests: XCTestCase {
    func testAirPlayTransportIsClassifiedAirPlay() {
        let device = DeviceRecord(
            uid: "AirPlay-LivingRoom",
            name: "Living Room",
            manufacturer: "Apple Inc.",
            transportType: kAudioDeviceTransportTypeAirPlay,
            inputChannelCount: 0,
            outputChannelCount: 2,
            sampleRate: 44_100
        )
        XCTAssertEqual(DeviceClassifier.classify(device), .airPlay)
        XCTAssertTrue(DeviceClassifier.isAirPlay(device))
        XCTAssertEqual(device.transportName, "AirPlay")
        XCTAssertFalse(AirPlayPolicy.allowsSharedLocalClock(device))
    }

    func testUSBMultiChannelInterfaceIsMusicAndAllowedInLocalMix() {
        let device = DeviceRecord(
            uid: "USB-Interface-8ch",
            name: "Studio 1824c",
            manufacturer: "PreSonus",
            transportType: kAudioDeviceTransportTypeUSB,
            inputChannelCount: 8,
            outputChannelCount: 8,
            sampleRate: 48_000
        )
        XCTAssertEqual(DeviceClassifier.classify(device), .musicInterface)
        XCTAssertFalse(DeviceClassifier.isAirPlay(device))
        XCTAssertTrue(AirPlayPolicy.allowsSharedLocalClock(device))
        XCTAssertEqual(device.transportName, "USB")
    }

    func testThunderboltMultiChannelInterfaceIsMusic() {
        let device = DeviceRecord(
            uid: "TBT-Interface",
            name: "Apollo x8",
            manufacturer: "Universal Audio",
            transportType: kAudioDeviceTransportTypeThunderbolt,
            inputChannelCount: 16,
            outputChannelCount: 16,
            sampleRate: 96_000
        )
        XCTAssertEqual(DeviceClassifier.classify(device), .musicInterface)
        XCTAssertTrue(AirPlayPolicy.allowsSharedLocalClock(device))
    }

    func testBuiltInStereoIsLocalNotAirPlay() {
        let device = DeviceRecord(
            uid: "BuiltIn-Speakers",
            name: "MacBook Air Speakers",
            manufacturer: "Apple Inc.",
            transportType: kAudioDeviceTransportTypeBuiltIn,
            inputChannelCount: 1,
            outputChannelCount: 2,
            sampleRate: 48_000
        )
        XCTAssertEqual(DeviceClassifier.classify(device), .local)
        XCTAssertFalse(DeviceClassifier.isAirPlay(device))
        XCTAssertTrue(AirPlayPolicy.allowsSharedLocalClock(device))
    }

    func testVirtualTransportIsVirtual() {
        let device = DeviceRecord(
            uid: "MixyHALDevice_UID",
            name: "Mixy Loopback",
            transportType: kAudioDeviceTransportTypeVirtual,
            inputChannelCount: 8,
            outputChannelCount: 8
        )
        XCTAssertEqual(DeviceClassifier.classify(device), .virtual)
        XCTAssertTrue(AirPlayPolicy.allowsSharedLocalClock(device))
    }

    func testLiveHALEnumerationPopulatesClassificationFields() throws {
        let devices = HALDeviceEnumerator.enumerateDevices()
        XCTAssertFalse(devices.isEmpty, "live HAL must report at least one device")
        let builtIn = devices.first {
            $0.transportType == kAudioDeviceTransportTypeBuiltIn
                || $0.name.localizedCaseInsensitiveContains("MacBook")
                || $0.name.localizedCaseInsensitiveContains("Built-in")
                || $0.name.localizedCaseInsensitiveContains("Speaker")
                || $0.name.localizedCaseInsensitiveContains("Microphone")
        }
        XCTAssertNotNil(builtIn, "expected the machine's built-in device in the live inventory")
        if let builtIn {
            XCTAssertFalse(DeviceClassifier.isAirPlay(builtIn))
            XCTAssertGreaterThan(builtIn.inputChannelCount + builtIn.outputChannelCount, 0)
            XCTAssertFalse(builtIn.transportName.isEmpty)
            XCTAssertNotEqual(DeviceClassifier.classify(builtIn), .airPlay)
        }
        for device in devices {
            XCTAssertFalse(device.uid.isEmpty)
            XCTAssertFalse(device.name.isEmpty)
            _ = DeviceClassifier.classify(device)
        }
    }
}
