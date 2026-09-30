import Foundation

/// sRGB token the console views paint. Tests assert distinct mute/solo/enabled fills.
public struct MixerColorToken: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double

    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }

    public static let muteLit = MixerColorToken(red: 0.93, green: 0.24, blue: 0.20)
    public static let soloLit = MixerColorToken(red: 0.97, green: 0.78, blue: 0.16)
    public static let enabledLit = MixerColorToken(red: 0.28, green: 0.78, blue: 0.42)
    public static let padOff = MixerColorToken(red: 0.24, green: 0.25, blue: 0.27)
    public static let enabledOff = MixerColorToken(red: 0.18, green: 0.19, blue: 0.20)
    public static let textOnLit = MixerColorToken(red: 0.08, green: 0.08, blue: 0.08)
    public static let textOff = MixerColorToken(red: 0.78, green: 0.80, blue: 0.82)
    public static let textDisabled = MixerColorToken(red: 0.46, green: 0.47, blue: 0.48)
    public static let hardware = MixerColorToken(red: 0.40, green: 0.72, blue: 1.00)
    public static let application = MixerColorToken(red: 0.42, green: 0.86, blue: 0.72)
    public static let output = MixerColorToken(red: 0.72, green: 0.62, blue: 0.98)
    public static let airPlay = MixerColorToken(red: 1.00, green: 0.62, blue: 0.22)
    public static let music = MixerColorToken(red: 0.74, green: 0.48, blue: 0.96)
    public static let virtual = MixerColorToken(red: 0.32, green: 0.78, blue: 0.78)
    public static let local = MixerColorToken(red: 0.45, green: 0.72, blue: 1.00)
}

/// Label + fill used by mute, solo, and on/off pads.
public struct MixerControlChrome: Equatable, Sendable {
    public var label: String
    public var isLit: Bool
    public var fill: MixerColorToken
    public var text: MixerColorToken

    public init(label: String, isLit: Bool, fill: MixerColorToken, text: MixerColorToken) {
        self.label = label
        self.isLit = isLit
        self.fill = fill
        self.text = text
    }
}

/// Empty / hidden desk copy the console paints.
public struct MixerDeskCopy: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var systemImage: String

    public init(title: String, detail: String, systemImage: String) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
    }
}

/// Presentation mappings for the polished mixer. Views consume these; tests call them.
public enum MixerChrome: Sendable {
    public static func muteChrome(isMuted: Bool) -> MixerControlChrome {
        MixerControlChrome(
            label: "M",
            isLit: isMuted,
            fill: isMuted ? .muteLit : .padOff,
            text: isMuted ? .textOnLit : .textOff
        )
    }

    public static func soloChrome(isSoloed: Bool) -> MixerControlChrome {
        MixerControlChrome(
            label: "S",
            isLit: isSoloed,
            fill: isSoloed ? .soloLit : .padOff,
            text: isSoloed ? .textOnLit : .textOff
        )
    }

    public static func enabledChrome(isEnabled: Bool) -> MixerControlChrome {
        MixerControlChrome(
            label: isEnabled ? "ON" : "OFF",
            isLit: isEnabled,
            fill: isEnabled ? .enabledLit : .enabledOff,
            text: isEnabled ? .textOnLit : .textDisabled
        )
    }

    public static func panLabel(_ pan: Float) -> String {
        if abs(pan) < 0.02 { return "C" }
        return pan < 0
            ? String(format: "L%.0f", -pan * 100)
            : String(format: "R%.0f", pan * 100)
    }

    public static func gainLabel(_ decibels: Float) -> String {
        String(format: "%+.1f dB", decibels)
    }

    public static func channelCountLabel(_ count: Int) -> String {
        "\(count) ch"
    }

    public static func roleLabel(isInput: Bool) -> String {
        isInput ? "IN" : "OUT"
    }

    public static func kindBadgeLabel(_ kind: DeviceKind) -> String {
        switch kind {
        case .airPlay: return "AP"
        case .musicInterface: return "MUSIC"
        case .local: return "LOCAL"
        case .virtual: return "VIRT"
        }
    }

    public static func kindToken(_ kind: DeviceKind) -> MixerColorToken {
        switch kind {
        case .airPlay: return .airPlay
        case .musicInterface: return .music
        case .local: return .local
        case .virtual: return .virtual
        }
    }

    public static func groupAccent(_ group: MixerChannelGroup) -> MixerColorToken {
        switch group {
        case .hardwareInputs: return .hardware
        case .applicationInputs: return .application
        case .localOutputs: return .output
        case .airPlay: return .airPlay
        }
    }

    public static func bankTitle(_ group: MixerChannelGroup) -> String {
        group.rawValue.uppercased()
    }

    public static func onMixerSectionTitle(_ group: MixerChannelGroup) -> String {
        "On Mixer — \(group.rawValue)"
    }

    public static func addSectionTitle(_ group: MixerChannelGroup) -> String {
        group.menuTitle
    }

    public static func applicationBadgeLabel(kind: InputKind) -> String? {
        switch kind {
        case .systemWideAppTap: return "ALL APPS"
        case .application: return "APP"
        case .hardware: return nil
        }
    }

    public static func stripOpacity(isMuted: Bool, isEnabled: Bool) -> Double {
        switch (isMuted, isEnabled) {
        case (true, false): return 0.48
        case (true, true): return 0.62
        case (false, false): return 0.55
        case (false, true): return 1.0
        }
    }

    public static func emptyDeskCopy() -> MixerDeskCopy {
        MixerDeskCopy(
            title: "Empty mixer",
            detail: "Add hardware, applications, outputs, or AirPlay from the Track Manager or Mixer → Add Channel menu.",
            systemImage: "slider.vertical.3"
        )
    }

    public static func hiddenGroupsCopy() -> MixerDeskCopy {
        MixerDeskCopy(
            title: "All groups hidden",
            detail: "Turn a group back on in View to show its channel strips.",
            systemImage: "eye.slash"
        )
    }

    public static func emptyCatalogCopy() -> String {
        "All added, or none available"
    }

    public static let faderTickDecibels: [Double] = [12, 0, -12, -24, -48, -96]

    public static func faderNormalized(value: Double, range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span != 0 else { return 0 }
        return (value - range.lowerBound) / span
    }
}
