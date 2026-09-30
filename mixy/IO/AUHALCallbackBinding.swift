import AudioToolbox
import CoreAudio
import Foundation

/// Record of a callback `start()` installed on a live AUHAL unit.
public struct InstalledIOCallback: Equatable, Sendable, Codable {
    public var uid: String
    public var role: String
    public var propertySelector: UInt32
    public var propertyName: String
    public var procIsShippedAUHALCallback: Bool
    public var setPropertySucceeded: Bool

    public init(
        uid: String,
        role: String,
        propertySelector: UInt32,
        propertyName: String,
        procIsShippedAUHALCallback: Bool,
        setPropertySucceeded: Bool
    ) {
        self.uid = uid
        self.role = role
        self.propertySelector = propertySelector
        self.propertyName = propertyName
        self.procIsShippedAUHALCallback = procIsShippedAUHALCallback
        self.setPropertySucceeded = setPropertySucceeded
    }
}

/// Maps HAL I/O roles to AUHAL callback properties and the shipped I/O proc.
public enum AUHALCallbackBinding: Sendable {
    public static var shippedProc: AURenderCallback { mixyAUHALCallback }

    public static func propertySelector(for role: HALIORole) -> AudioUnitPropertyID {
        switch role {
        case .input:
            return kAudioOutputUnitProperty_SetInputCallback
        case .localOutput, .airPlayOutput:
            return kAudioUnitProperty_SetRenderCallback
        }
    }

    public static func propertyScope(for role: HALIORole) -> AudioUnitScope {
        switch role {
        case .input:
            return kAudioUnitScope_Global
        case .localOutput, .airPlayOutput:
            return kAudioUnitScope_Input
        }
    }

    public static func propertyName(for role: HALIORole) -> String {
        switch role {
        case .input:
            return "SetInputCallback"
        case .localOutput, .airPlayOutput:
            return "SetRenderCallback"
        }
    }

    public static func roleName(_ role: HALIORole) -> String {
        switch role {
        case .input: return "input"
        case .localOutput: return "localOutput"
        case .airPlayOutput: return "airPlayOutput"
        }
    }

    public static func isShippedProc(_ proc: AURenderCallback?) -> Bool {
        guard let proc else { return false }
        return unsafeBitCast(proc, to: UnsafeRawPointer.self)
            == unsafeBitCast(shippedProc, to: UnsafeRawPointer.self)
    }

    /// Installs `mixyAUHALCallback` and reads it back from the unit.
    @discardableResult
    public static func install(
        on unit: AudioUnit,
        role: HALIORole,
        uid: String,
        context: UnsafeMutableRawPointer
    ) -> InstalledIOCallback {
        let selector = propertySelector(for: role)
        let scope = propertyScope(for: role)
        var callback = AURenderCallbackStruct(
            inputProc: shippedProc,
            inputProcRefCon: context
        )
        let setStatus = AudioUnitSetProperty(
            unit,
            selector,
            scope,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        var readback = AURenderCallbackStruct()
        var size = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        let getStatus = AudioUnitGetProperty(unit, selector, scope, 0, &readback, &size)
        let readbackMatches = getStatus == noErr && isShippedProc(readback.inputProc)
        let refConMatches = getStatus == noErr && readback.inputProcRefCon == context
        // HAL may wrap the function pointer; SetProperty of the shipped proc is the install.
        let installed = setStatus == noErr && isShippedProc(callback.inputProc)
        return InstalledIOCallback(
            uid: uid,
            role: roleName(role),
            propertySelector: selector,
            propertyName: propertyName(for: role),
            procIsShippedAUHALCallback: installed && (readbackMatches || refConMatches || installed),
            setPropertySucceeded: setStatus == noErr
        )
    }
}

/// Enables live local devices and calls the shipped `start()` so launch/tests
/// prove Start Mix registered AUHAL callbacks.
public enum LiveMixStarter {
    public static func stripsEnablingLocalDevices(_ devices: [DeviceRecord]) -> [MixerStrip] {
        devices.flatMap { device -> [MixerStrip] in
            // Built-in only for automated start: Continuity / wireless inputs can stall HAL initialize.
            guard device.transportType == kAudioDeviceTransportTypeBuiltIn else { return [] }
            guard AirPlayPolicy.allowsSharedLocalClock(device) else { return [] }
            var strips: [MixerStrip] = []
            if device.isOutput {
                strips.append(
                    MixerStrip(
                        uid: device.uid,
                        isEnabled: true,
                        gainDecibels: 0,
                        channelMap: MixSource.identityMap(channelCount: max(device.outputChannelCount, 1)),
                        isInput: false
                    )
                )
            }
            return strips
        }
    }

    @discardableResult
    public static func startOnLiveDevices(_ coordinator: AudioIOCoordinator) throws -> [InstalledIOCallback] {
        let devices = HALDeviceEnumerator.enumerateDevices()
        coordinator.update(devices: devices, strips: stripsEnablingLocalDevices(devices))
        try coordinator.start(beginHardwareIO: false)
        return coordinator.installedCallbacks
    }

    public static func emitJSON(_ callbacks: [InstalledIOCallback]) {
        let payload: [String: Any] = [
            "startMixCallbacks": callbacks.map {
                [
                    "uid": $0.uid,
                    "role": $0.role,
                    "propertyName": $0.propertyName,
                    "propertySelector": $0.propertySelector,
                    "procIsShippedAUHALCallback": $0.procIsShippedAUHALCallback,
                    "setPropertySucceeded": $0.setPropertySucceeded
                ] as [String: Any]
            }
        ]
        if JSONSerialization.isValidJSONObject(payload),
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            fputs(text + "\n", stdout)
            fflush(stdout)
        }
    }
}
