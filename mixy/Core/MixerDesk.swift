import Foundation

/// Mixer banks, following Logic / Pro Tools / Reaper: only included channels sit on the desk.
public enum MixerChannelGroup: String, CaseIterable, Sendable, Equatable, Hashable, Identifiable {
    case hardwareInputs = "Hardware Inputs"
    case applicationInputs = "Application Audio"
    case localOutputs = "Outputs"
    case airPlay = "AirPlay"

    public var id: String { rawValue }

    public var menuTitle: String {
        switch self {
        case .hardwareInputs: return "Add Hardware Input"
        case .applicationInputs: return "Add Application"
        case .localOutputs: return "Add Output"
        case .airPlay: return "Add AirPlay Destination"
        }
    }

    public var systemImage: String {
        switch self {
        case .hardwareInputs: return "mic"
        case .applicationInputs: return "app.badge"
        case .localOutputs: return "hifispeaker"
        case .airPlay: return "airplayaudio"
        }
    }
}

public struct MixerBank: Equatable, Sendable, Identifiable {
    public var group: MixerChannelGroup
    public var strips: [MixerStrip]

    public var id: MixerChannelGroup { group }

    public init(group: MixerChannelGroup, strips: [MixerStrip]) {
        self.group = group
        self.strips = strips
    }
}

/// Groups included strips and lists catalog items not yet on the desk.
public enum MixerDesk: Sendable {
    public static func group(
        for strip: MixerStrip,
        inputs: [InputSource],
        destinations: [OutputDestination]
    ) -> MixerChannelGroup {
        if strip.isInput {
            if let source = inputs.first(where: { $0.uid == strip.uid }), source.isApplicationAudio {
                return .applicationInputs
            }
            return .hardwareInputs
        }
        if destinations.first(where: { $0.uid == strip.uid })?.isAirPlay == true {
            return .airPlay
        }
        return .localOutputs
    }

    public static func banks(
        strips: [MixerStrip],
        inputs: [InputSource],
        destinations: [OutputDestination]
    ) -> [MixerBank] {
        MixerChannelGroup.allCases.compactMap { group in
            let members = strips.filter { self.group(for: $0, inputs: inputs, destinations: destinations) == group }
            guard !members.isEmpty else { return nil }
            return MixerBank(group: group, strips: members)
        }
    }

    public static func availableInputs(
        catalog: [InputSource],
        inMixer: Set<String>,
        playingOnly: Bool
    ) -> [InputSource] {
        catalog.filter { source in
            guard !inMixer.contains(source.uid) else { return false }
            if playingOnly, source.kind == .application, !source.isRunningOutput {
                return false
            }
            return true
        }
    }

    public static func availableOutputs(
        catalog: [OutputDestination],
        inMixer: Set<String>,
        airPlayOnly: Bool?
    ) -> [OutputDestination] {
        catalog.filter { dest in
            guard !inMixer.contains(dest.uid) else { return false }
            if let airPlayOnly {
                return dest.isAirPlay == airPlayOnly
            }
            return true
        }
    }

    public static func inMixerUIDs(strips: [MixerStrip]) -> Set<String> {
        Set(strips.map(\.uid))
    }

    public static func banks(
        _ banks: [MixerBank],
        visibleGroups: Set<MixerChannelGroup>
    ) -> [MixerBank] {
        banks.filter { visibleGroups.contains($0.group) }
    }

    public static func strips(
        in group: MixerChannelGroup,
        strips: [MixerStrip],
        inputs: [InputSource],
        destinations: [OutputDestination]
    ) -> [MixerStrip] {
        strips.filter { self.group(for: $0, inputs: inputs, destinations: destinations) == group }
    }

    /// Keep fader/mute/solo/pan when the I/O assignment on a strip changes (Logic/Reaper).
    public static func transferringControls(from existing: MixerStrip, onto next: MixerStrip) -> MixerStrip {
        var copy = next
        copy.gainDecibels = existing.gainDecibels
        copy.isMuted = existing.isMuted
        copy.isSoloed = existing.isSoloed
        copy.pan = existing.pan
        copy.isEnabled = existing.isEnabled
        return copy
    }
}
