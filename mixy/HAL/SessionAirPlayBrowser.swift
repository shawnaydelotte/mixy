import Foundation

/// Browses the current user's local network for AirPlay / RAOP endpoints
/// that may not yet appear as HAL audio devices.
public final class SessionAirPlayBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let airPlayBrowser = NetServiceBrowser()
    private let raopBrowser = NetServiceBrowser()
    private var resolving: [NetService] = []
    private var endpointsByUID: [String: SessionAirPlayEndpoint] = [:]
    private let lock = NSLock()
    private var started = false

    public var onChange: (([SessionAirPlayEndpoint]) -> Void)?

    public var endpoints: [SessionAirPlayEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        return endpointsByUID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public override init() {
        super.init()
        airPlayBrowser.delegate = self
        raopBrowser.delegate = self
    }

    public func start() {
        guard !started else { return }
        started = true
        airPlayBrowser.searchForServices(ofType: "_airplay._tcp.", inDomain: "local.")
        raopBrowser.searchForServices(ofType: "_raop._tcp.", inDomain: "local.")
    }

    public func stop() {
        airPlayBrowser.stop()
        raopBrowser.stop()
        started = false
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.resolve(withTimeout: 3)
        resolving.append(service)
        ingest(service, from: browser)
        if !moreComing { emit() }
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let uid = SessionAirPlayEndpoint.uid(
            serviceType: serviceType(of: service, browser: browser),
            name: displayName(for: service)
        )
        lock.lock()
        endpointsByUID.removeValue(forKey: uid)
        lock.unlock()
        if !moreComing { emit() }
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        ingest(sender, from: nil)
        emit()
    }

    private func ingest(_ service: NetService, from browser: NetServiceBrowser?) {
        let type = serviceType(of: service, browser: browser)
        let name = displayName(for: service)
        guard !name.isEmpty else { return }
        let endpoint = SessionAirPlayEndpoint(
            uid: SessionAirPlayEndpoint.uid(serviceType: type, name: name),
            name: name,
            supportsVideo: type.contains("airplay"),
            serviceType: type
        )
        lock.lock()
        endpointsByUID[endpoint.uid] = endpoint
        lock.unlock()
    }

    private func serviceType(of service: NetService, browser: NetServiceBrowser?) -> String {
        let raw = service.type
        if raw.contains("airplay") { return "_airplay._tcp" }
        if raw.contains("raop") { return "_raop._tcp" }
        if browser === airPlayBrowser { return "_airplay._tcp" }
        return "_raop._tcp"
    }

    /// RAOP names look like `AABBCCDDEEFF@Living Room`.
    public static func displayName(fromServiceName name: String) -> String {
        if let at = name.firstIndex(of: "@") {
            let rest = name[name.index(after: at)...]
            let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed) }
        }
        return name
    }

    private func displayName(for service: NetService) -> String {
        Self.displayName(fromServiceName: service.name)
    }

    private func emit() {
        onChange?(endpoints)
    }
}
