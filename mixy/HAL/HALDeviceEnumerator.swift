import CoreAudio
import Foundation

/// Thin adapter over the live Core Audio HAL. Not used by mix/classify unit tests.
public enum HALDeviceEnumerator: Sendable {
    public static func enumerateDevices() -> [DeviceRecord] {
        let ids: [AudioObjectID] = HALProperty.array(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
        return ids.compactMap(describe(device:))
    }

    public static func describe(device id: AudioObjectID) -> DeviceRecord? {
        let uid = HALProperty.cfString(object: id, selector: kAudioDevicePropertyDeviceUID)
            ?? String(id)
        let name = HALProperty.cfString(object: id, selector: kAudioObjectPropertyName)
            ?? HALProperty.cfString(object: id, selector: kAudioDevicePropertyDeviceUID)
            ?? "Device \(id)"
        let manufacturer = HALProperty.cfString(object: id, selector: kAudioObjectPropertyManufacturer)
            ?? ""
        let transport: UInt32 = HALProperty.value(
            object: id,
            selector: kAudioDevicePropertyTransportType
        ) ?? kAudioDeviceTransportTypeUnknown
        let inputChannels = HALProperty.channelCount(object: id, scope: kAudioObjectPropertyScopeInput)
        let outputChannels = HALProperty.channelCount(object: id, scope: kAudioObjectPropertyScopeOutput)
        let sampleRate: Float64 = HALProperty.value(
            object: id,
            selector: kAudioDevicePropertyNominalSampleRate
        ) ?? 48_000
        return DeviceRecord(
            uid: uid,
            name: name,
            manufacturer: manufacturer,
            transportType: transport,
            inputChannelCount: inputChannels,
            outputChannelCount: outputChannels,
            sampleRate: sampleRate
        )
    }

    public static func defaultInputUID() -> String? {
        guard let id: AudioObjectID = HALProperty.value(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice
        ), id != kAudioObjectUnknown else { return nil }
        return HALProperty.cfString(object: id, selector: kAudioDevicePropertyDeviceUID)
    }

    public static func defaultOutputUID() -> String? {
        guard let id: AudioObjectID = HALProperty.value(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ), id != kAudioObjectUnknown else { return nil }
        return HALProperty.cfString(object: id, selector: kAudioDevicePropertyDeviceUID)
    }

    public static func audioObjectID(forUID uid: String) -> AudioObjectID? {
        let ids: [AudioObjectID] = HALProperty.array(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
        for id in ids {
            if HALProperty.cfString(object: id, selector: kAudioDevicePropertyDeviceUID) == uid {
                return id
            }
        }
        return nil
    }
}

/// Observes HAL device list changes and rebuilds the mixer graph via AirPlay policy.
public final class HALDeviceMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mixy.hal-monitor")
    private var started = false

    public var onDevicesChanged: (([DeviceRecord]) -> Void)?

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            queue
        ) { [weak self] _, _ in
            self?.emit()
        }
        var defaultOut = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOut,
            queue
        ) { [weak self] _, _ in
            self?.emit()
        }
        // Defer the first snapshot so SwiftUI lists are not mutated mid-update.
        queue.async { [weak self] in
            self?.emit()
        }
    }

    private func emit() {
        let devices = HALDeviceEnumerator.enumerateDevices()
        onDevicesChanged?(devices)
    }
}
