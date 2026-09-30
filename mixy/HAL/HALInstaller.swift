import Foundation

public enum HALInstallerError: Error, LocalizedError, Sendable {
    case bundledDriverMissing
    case copyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .bundledDriverMissing:
            return "MixyHAL.driver is not embedded in the app bundle."
        case .copyFailed(let message):
            return message
        }
    }
}

/// Copies the first-party Audio Server Plug-in into /Library/Audio/Plug-Ins/HAL.
/// Requires admin; sandbox and missing privileges are expected to fail.
public enum HALInstaller {
    public static let systemDirectory = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL", isDirectory: true)
    public static let systemDriverURL = systemDirectory.appendingPathComponent("MixyHAL.driver")

    public static var bundledDriverURL: URL? {
        Bundle.main.url(forResource: "MixyHAL", withExtension: "driver")
            ?? Bundle.main.builtInPlugInsURL?.appendingPathComponent("MixyHAL.driver")
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: systemDriverURL.path)
    }

    public static func install() -> Result<URL, HALInstallerError> {
        guard let source = bundledDriverURL, FileManager.default.fileExists(atPath: source.path) else {
            return .failure(.bundledDriverMissing)
        }
        do {
            try FileManager.default.createDirectory(at: systemDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: systemDriverURL.path) {
                try FileManager.default.removeItem(at: systemDriverURL)
            }
            try FileManager.default.copyItem(at: source, to: systemDriverURL)
            return .success(systemDriverURL)
        } catch {
            return .failure(.copyFailed(error.localizedDescription))
        }
    }
}
