import Foundation

public enum InputKind: String, Codable, Sendable, Equatable {
    case hardware
    case application
    case systemWideAppTap
}

/// A selectable mixer input: hardware HAL device or application-audio tap.
public struct InputSource: Equatable, Sendable, Codable, Identifiable {
    public var uid: String
    public var name: String
    public var kind: InputKind
    public var inputChannelCount: Int
    public var transportName: String
    public var bundleID: String?
    public var processObjectID: UInt32?
    public var pid: Int32?
    public var isRunningOutput: Bool

    public var id: String { uid }
    public var isHardware: Bool { kind == .hardware }
    public var isApplicationAudio: Bool { kind == .application || kind == .systemWideAppTap }

    public static let systemWideUID = "app:system-wide"

    public init(
        uid: String,
        name: String,
        kind: InputKind,
        inputChannelCount: Int,
        transportName: String,
        bundleID: String? = nil,
        processObjectID: UInt32? = nil,
        pid: Int32? = nil,
        isRunningOutput: Bool = false
    ) {
        self.uid = uid
        self.name = name
        self.kind = kind
        self.inputChannelCount = inputChannelCount
        self.transportName = transportName
        self.bundleID = bundleID
        self.processObjectID = processObjectID
        self.pid = pid
        self.isRunningOutput = isRunningOutput
    }

    public init(hal device: DeviceRecord) {
        self.init(
            uid: device.uid,
            name: device.name,
            kind: .hardware,
            inputChannelCount: device.inputChannelCount,
            transportName: device.transportName,
            isRunningOutput: false
        )
    }

    public init(process: AppAudioProcess) {
        self.init(
            uid: process.uid,
            name: process.name,
            kind: .application,
            inputChannelCount: 2,
            transportName: "Application",
            bundleID: process.bundleID,
            processObjectID: process.objectID,
            pid: process.pid,
            isRunningOutput: process.isRunningOutput
        )
    }

    public static var systemWideTap: InputSource {
        InputSource(
            uid: systemWideUID,
            name: "All Application Audio",
            kind: .systemWideAppTap,
            inputChannelCount: 2,
            transportName: "Application",
            isRunningOutput: true
        )
    }
}

public struct AppAudioProcess: Equatable, Sendable, Codable, Identifiable {
    public var objectID: UInt32
    public var pid: Int32
    public var bundleID: String
    public var name: String
    public var isRunningOutput: Bool

    public var id: String { uid }
    public var uid: String { "app:\(bundleID.isEmpty ? "pid" : bundleID):\(pid)" }

    public init(objectID: UInt32, pid: Int32, bundleID: String, name: String, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isRunningOutput = isRunningOutput
    }
}

/// Selected hardware vs application inputs. App sources never enter output/AirPlay sets.
public struct InputGraph: Equatable, Sendable, Codable {
    public var hardwareInputUIDs: [String]
    public var applicationInputUIDs: [String]

    public init(hardwareInputUIDs: [String], applicationInputUIDs: [String]) {
        self.hardwareInputUIDs = hardwareInputUIDs
        self.applicationInputUIDs = applicationInputUIDs
    }
}

public enum InputCatalog: Sendable {
    public static func merge(
        halDevices: [DeviceRecord],
        processes: [AppAudioProcess],
        includeSystemWideTap: Bool = true
    ) -> [InputSource] {
        var sources: [InputSource] = []
        for device in halDevices where device.isInput {
            sources.append(InputSource(hal: device))
        }
        if includeSystemWideTap {
            sources.append(.systemWideTap)
        }
        for process in processes {
            sources.append(InputSource(process: process))
        }
        return sources.sorted {
            if $0.kind != $1.kind {
                return kindOrder($0.kind) < kindOrder($1.kind)
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func hardwareInputs(in sources: [InputSource]) -> [InputSource] {
        sources.filter(\.isHardware)
    }

    public static func applicationInputs(in sources: [InputSource]) -> [InputSource] {
        sources.filter(\.isApplicationAudio)
    }

    private static func kindOrder(_ kind: InputKind) -> Int {
        switch kind {
        case .hardware: return 0
        case .systemWideAppTap: return 1
        case .application: return 2
        }
    }
}

public enum InputRouter: Sendable {
    public static func graph(inputs: [InputSource], selectedUIDs: Set<String>) -> InputGraph {
        let selected = inputs.filter { selectedUIDs.contains($0.uid) }
        return InputGraph(
            hardwareInputUIDs: selected.filter(\.isHardware).map(\.uid),
            applicationInputUIDs: selected.filter(\.isApplicationAudio).map(\.uid)
        )
    }

    /// Application-audio UIDs must not appear as local-clock or isolated-AirPlay outputs.
    public static func isTreatedAsOutput(uid: String, mixGraph: MixGraph) -> Bool {
        mixGraph.localClockDeviceUIDs.contains(uid) || mixGraph.isolatedAirPlayUIDs.contains(uid)
    }

    public static func inputStrip(for source: InputSource, enabled: Bool, existing: MixerStrip?) -> MixerStrip {
        if var existing {
            existing.isEnabled = enabled
            return existing
        }
        return MixerStrip(
            uid: source.uid,
            isEnabled: enabled,
            gainDecibels: 0,
            channelMap: StripMix.destChannelMap(
                stripMap: MixSource.identityMap(channelCount: max(source.inputChannelCount, 1)),
                sourceChannelCount: max(source.inputChannelCount, 1),
                destinationChannelCount: max(source.inputChannelCount, 2)
            ),
            isInput: true
        )
    }
}
