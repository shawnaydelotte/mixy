import CoreAudio
import Foundation

/// Classifies HAL device records from transport type and channel counts.
public enum DeviceClassifier: Sendable {
    public static func isAirPlay(_ device: DeviceRecord) -> Bool {
        AudioTransport.isAirPlay(device.transportType)
    }

    public static func classify(_ device: DeviceRecord) -> DeviceKind {
        if AudioTransport.isAirPlay(device.transportType) {
            return .airPlay
        }
        if AudioTransport.isVirtual(device.transportType) {
            return .virtual
        }
        let channels = max(device.inputChannelCount, device.outputChannelCount)
        if AudioTransport.isMusicInterfaceTransport(device.transportType), channels > 2 {
            return .musicInterface
        }
        return .local
    }
}
