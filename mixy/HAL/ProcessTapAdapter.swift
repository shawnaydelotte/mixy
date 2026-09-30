import CoreAudio
import Foundation

public enum ProcessTapError: Error, LocalizedError, Sendable {
    case createFailed(OSStatus)
    case tapUIDMissing
    case aggregateFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .createFailed(let status):
            return "AudioHardwareCreateProcessTap failed (\(status))"
        case .tapUIDMissing:
            return "Process tap has no UID"
        case .aggregateFailed(let status):
            return "AudioHardwareCreateAggregateDevice failed (\(status))"
        }
    }
}

public struct ProcessTapSession: Equatable, Sendable {
    public var tapID: AudioObjectID
    public var tapUID: String
    public var aggregateUID: String
    public var aggregateDeviceID: AudioObjectID
    public var sourceUID: String
}

/// First-party Core Audio process tap → private aggregate input device.
public enum ProcessTapAdapter {
    public static func description(for source: InputSource) -> CATapDescription {
        let description: CATapDescription
        if source.kind == .systemWideAppTap {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "Mixy All Application Audio"
        } else if let objectID = source.processObjectID {
            description = CATapDescription(stereoMixdownOfProcesses: [objectID])
            description.name = "Mixy Tap \(source.name)"
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "Mixy Tap \(source.name)"
        }
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    public static func createTap(description: CATapDescription) -> Result<AudioObjectID, ProcessTapError> {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            return .failure(.createFailed(status))
        }
        return .success(tapID)
    }

    public static func tapUID(for tapID: AudioObjectID) -> String? {
        HALProperty.cfString(object: tapID, selector: kAudioTapPropertyUID)
    }

    public static func attachTapAsInputDevice(
        tapID: AudioObjectID,
        sourceUID: String,
        name: String
    ) -> Result<ProcessTapSession, ProcessTapError> {
        guard let tapUID = tapUID(for: tapID) else {
            return .failure(.tapUIDMissing)
        }
        let aggregateUID = "mixy.tap.\(sourceUID)"
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mixy Input — \(name)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID]
            ]
        ]
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return .failure(.aggregateFailed(status))
        }
        return .success(
            ProcessTapSession(
                tapID: tapID,
                tapUID: tapUID,
                aggregateUID: aggregateUID,
                aggregateDeviceID: deviceID,
                sourceUID: sourceUID
            )
        )
    }

    /// Private tap aggregates are not in `kAudioHardwarePropertyDevices`; use this ID.
    public static func inputDeviceID(for session: ProcessTapSession) -> AudioObjectID {
        session.aggregateDeviceID
    }

    public static func activate(source: InputSource) -> Result<ProcessTapSession, ProcessTapError> {
        switch createTap(description: description(for: source)) {
        case .failure(let error):
            return .failure(error)
        case .success(let tapID):
            let attached = attachTapAsInputDevice(tapID: tapID, sourceUID: source.uid, name: source.name)
            if case .failure = attached {
                AudioHardwareDestroyProcessTap(tapID)
            }
            return attached
        }
    }

    public static func teardown(_ session: ProcessTapSession) {
        AudioHardwareDestroyAggregateDevice(session.aggregateDeviceID)
        AudioHardwareDestroyProcessTap(session.tapID)
    }
}
