import Foundation

public struct VideoRouteEntry: Equatable, Sendable, Codable, Identifiable {
    public var uid: String
    public var name: String
    public var isAirPlay: Bool
    public var isSelected: Bool

    public var id: String { uid }

    public init(uid: String, name: String, isAirPlay: Bool, isSelected: Bool) {
        self.uid = uid
        self.name = name
        self.isAirPlay = isAirPlay
        self.isSelected = isSelected
    }
}

/// Shipped video-route record tests (and the UI) read after selection changes.
public struct VideoRouteRecord: Equatable, Sendable, Codable {
    public var routes: [VideoRouteEntry]

    public var selectedUIDs: [String] {
        routes.filter(\.isSelected).map(\.uid)
    }

    public init(routes: [VideoRouteEntry] = []) {
        self.routes = routes
    }

    public func entry(uid: String) -> VideoRouteEntry? {
        routes.first { $0.uid == uid }
    }
}

/// Audio + video selection over the merged output catalog.
public enum AudioVideoRouter: Sendable {
    /// Selected local outputs join the local clock; selected AirPlay stays isolated.
    public static func audioGraph(
        destinations: [OutputDestination],
        selectedAudioUIDs: Set<String>
    ) -> MixGraph {
        let devices = destinations.map(\.asDeviceRecord)
        return AirPlayPolicy.buildGraph(devices: devices, enabledUIDs: selectedAudioUIDs)
    }

    public static func applyingAudioSelection(
        destinations: [OutputDestination],
        selectedAudioUIDs: Set<String>,
        toggling uid: String,
        enabled: Bool
    ) -> (selected: Set<String>, graph: MixGraph) {
        var next = selectedAudioUIDs
        if enabled {
            next.insert(uid)
        } else {
            next.remove(uid)
        }
        return (next, audioGraph(destinations: destinations, selectedAudioUIDs: next))
    }

    public static func videoRecord(
        destinations: [OutputDestination],
        selectedVideoUIDs: Set<String>
    ) -> VideoRouteRecord {
        let routes = destinations.filter(\.supportsVideo).map { dest in
            VideoRouteEntry(
                uid: dest.uid,
                name: dest.name,
                isAirPlay: dest.isAirPlay,
                isSelected: selectedVideoUIDs.contains(dest.uid)
            )
        }
        return VideoRouteRecord(routes: routes)
    }

    public static func applyingVideoSelection(
        destinations: [OutputDestination],
        selectedVideoUIDs: Set<String>,
        toggling uid: String,
        enabled: Bool
    ) -> (selected: Set<String>, record: VideoRouteRecord) {
        var next = selectedVideoUIDs
        if enabled {
            next.insert(uid)
        } else {
            next.remove(uid)
        }
        return (next, videoRecord(destinations: destinations, selectedVideoUIDs: next))
    }
}
