import Foundation

/// Live HAL inventory emitted on launch (stdout + optional path). Used by verification.
public enum DeviceInventory {
    public struct Payload: Codable, Sendable {
        public var timestamp: String
        public var hostname: String
        public var devices: [Entry]
        public var outputs: [OutputEntry]
        public var videoRoutes: [VideoEntry]
        public var inputs: [InputEntry]
    }

    public struct InputEntry: Codable, Sendable, Equatable {
        public var uid: String
        public var name: String
        public var kind: String
        public var isHardware: Bool
        public var isApplicationAudio: Bool
        public var inputChannelCount: Int
        public var transportName: String
        public var bundleID: String?
        public var selected: Bool
    }

    public struct OutputEntry: Codable, Sendable, Equatable {
        public var uid: String
        public var name: String
        public var source: String
        public var kindLabel: String
        public var isAirPlay: Bool
        public var supportsAudio: Bool
        public var supportsVideo: Bool
        public var outputChannelCount: Int
        public var audioSelected: Bool
        public var videoSelected: Bool
    }

    public struct VideoEntry: Codable, Sendable, Equatable {
        public var uid: String
        public var name: String
        public var isAirPlay: Bool
        public var isSelected: Bool
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var uid: String
        public var name: String
        public var manufacturer: String
        public var transportType: String
        public var transportName: String
        public var kind: String
        public var inputChannelCount: Int
        public var outputChannelCount: Int
        public var sampleRate: Double
        public var isInput: Bool
        public var isOutput: Bool
        public var isAirPlay: Bool
        public var allowsLocalClock: Bool
    }

    public static func entries(from devices: [DeviceRecord]) -> [Entry] {
        devices.map { device in
            Entry(
                uid: device.uid,
                name: device.name,
                manufacturer: device.manufacturer,
                transportType: device.transportFourCC,
                transportName: device.transportName,
                kind: DeviceClassifier.classify(device).rawValue,
                inputChannelCount: device.inputChannelCount,
                outputChannelCount: device.outputChannelCount,
                sampleRate: device.sampleRate,
                isInput: device.isInput,
                isOutput: device.isOutput,
                isAirPlay: DeviceClassifier.isAirPlay(device),
                allowsLocalClock: AirPlayPolicy.allowsSharedLocalClock(device)
            )
        }
    }

    public static func outputEntries(
        from destinations: [OutputDestination],
        selectedAudio: Set<String> = [],
        selectedVideo: Set<String> = []
    ) -> [OutputEntry] {
        destinations.map { dest in
            OutputEntry(
                uid: dest.uid,
                name: dest.name,
                source: dest.source.rawValue,
                kindLabel: dest.kindLabel,
                isAirPlay: dest.isAirPlay,
                supportsAudio: dest.supportsAudio,
                supportsVideo: dest.supportsVideo,
                outputChannelCount: dest.outputChannelCount,
                audioSelected: selectedAudio.contains(dest.uid),
                videoSelected: selectedVideo.contains(dest.uid)
            )
        }
    }

    public static func payload(
        from devices: [DeviceRecord],
        destinations: [OutputDestination] = [],
        videoRoutes: VideoRouteRecord = VideoRouteRecord(),
        selectedAudio: Set<String> = [],
        selectedVideo: Set<String> = [],
        inputs: [InputSource] = [],
        selectedInputs: Set<String> = [],
        now: Date = Date()
    ) -> Payload {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dests = destinations.isEmpty
            ? OutputCatalog.merge(halDevices: devices, sessionAirPlay: [])
            : destinations
        let inputList = inputs.isEmpty
            ? InputCatalog.merge(halDevices: devices, processes: [])
            : inputs
        return Payload(
            timestamp: formatter.string(from: now),
            hostname: ProcessInfo.processInfo.hostName,
            devices: entries(from: devices),
            outputs: outputEntries(from: dests, selectedAudio: selectedAudio, selectedVideo: selectedVideo),
            videoRoutes: videoRoutes.routes.map {
                VideoEntry(uid: $0.uid, name: $0.name, isAirPlay: $0.isAirPlay, isSelected: $0.isSelected)
            },
            inputs: inputList.map { source in
                InputEntry(
                    uid: source.uid,
                    name: source.name,
                    kind: source.kind.rawValue,
                    isHardware: source.isHardware,
                    isApplicationAudio: source.isApplicationAudio,
                    inputChannelCount: source.inputChannelCount,
                    transportName: source.transportName,
                    bundleID: source.bundleID,
                    selected: selectedInputs.contains(source.uid)
                )
            }
        )
    }

    public static func jsonString(from devices: [DeviceRecord]) throws -> String {
        try jsonString(payload: payload(from: devices))
    }

    public static func jsonString(payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    /// Enumerates the live HAL, prints JSON, and writes `MIXY_INVENTORY_PATH` when set.
    @discardableResult
    public static func emitFromLiveHAL() -> [DeviceRecord] {
        let devices = HALDeviceEnumerator.enumerateDevices()
        let processes = HALProcessEnumerator.enumerateProcesses()
        let inputs = InputCatalog.merge(halDevices: devices, processes: processes)
        do {
            let text = try jsonString(payload: payload(from: devices, inputs: inputs))
            fputs(text + "\n", stdout)
            fflush(stdout)
            if let path = ProcessInfo.processInfo.environment["MIXY_INVENTORY_PATH"], !path.isEmpty {
                try text.write(toFile: path, atomically: true, encoding: .utf8)
            }
        } catch {
            fputs("mixy: failed to encode device inventory: \(error)\n", stderr)
        }
        return devices
    }

    public static func probeProcessTap() -> String {
        let source = InputSource.systemWideTap
        switch ProcessTapAdapter.activate(source: source) {
        case .success(let session):
            ProcessTapAdapter.teardown(session)
            return "created tap \(session.tapUID) aggregate \(session.aggregateUID)"
        case .failure(let error):
            return error.localizedDescription
        }
    }
}
