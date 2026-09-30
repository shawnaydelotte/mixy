import AppKit
import CoreAudio
import Foundation

/// Lists Core Audio process objects (apps that can produce output audio).
public enum HALProcessEnumerator: Sendable {
    public static func enumerateProcesses() -> [AppAudioProcess] {
        let ids: [AudioObjectID] = HALProperty.array(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        )
        return ids.compactMap(describe(process:))
    }

    public static func describe(process id: AudioObjectID) -> AppAudioProcess? {
        let pid: pid_t = HALProperty.value(object: id, selector: kAudioProcessPropertyPID) ?? 0
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }
        let bundle = HALProperty.cfString(object: id, selector: kAudioProcessPropertyBundleID) ?? ""
        let name = displayName(bundleID: bundle, pid: pid)
        let running: UInt32 = HALProperty.value(object: id, selector: kAudioProcessPropertyIsRunningOutput) ?? 0
        return AppAudioProcess(
            objectID: id,
            pid: pid,
            bundleID: bundle,
            name: name,
            isRunningOutput: running != 0
        )
    }

    public static func displayName(bundleID: String, pid: pid_t) -> String {
        if !bundleID.isEmpty {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return url.deletingPathExtension().lastPathComponent
            }
            if let last = bundleID.split(separator: ".").last {
                return String(last)
            }
            return bundleID
        }
        return "Process \(pid)"
    }
}
