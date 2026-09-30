import Foundation

/// Merges HAL outputs with session AirPlay destinations (not only HAL-published ones).
public enum OutputCatalog: Sendable {
    public static func merge(
        halDevices: [DeviceRecord],
        sessionAirPlay: [SessionAirPlayEndpoint]
    ) -> [OutputDestination] {
        var destinations: [OutputDestination] = []
        for device in halDevices where device.isOutput {
            destinations.append(OutputDestination(hal: device))
        }
        for endpoint in sessionAirPlay {
            if let index = destinations.firstIndex(where: { matches($0, endpoint) }) {
                if endpoint.supportsVideo, !destinations[index].supportsVideo {
                    destinations[index].supportsVideo = true
                }
                continue
            }
            destinations.append(OutputDestination(session: endpoint))
        }
        return destinations.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func matches(_ destination: OutputDestination, _ endpoint: SessionAirPlayEndpoint) -> Bool {
        if destination.uid == endpoint.uid { return true }
        return destination.name.localizedCaseInsensitiveCompare(endpoint.name) == .orderedSame
            && destination.isAirPlay
    }

    public static func airPlayDestinations(in destinations: [OutputDestination]) -> [OutputDestination] {
        destinations.filter(\.isAirPlay)
    }

    public static func otherOutputs(in destinations: [OutputDestination]) -> [OutputDestination] {
        destinations.filter { !$0.isAirPlay }
    }
}
