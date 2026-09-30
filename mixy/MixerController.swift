import CoreAudio
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class MixerController {
    var devices: [DeviceRecord] = []
    var strips: [MixerStrip] = []
    var graph: MixGraph = MixGraph(
        localClockDeviceUIDs: [],
        isolatedAirPlayUIDs: [],
        bufferFramesLocal: AirPlayPolicy.localBufferFrames,
        bufferFramesAirPlay: AirPlayPolicy.airPlayBufferFrames,
        extraLatencyFramesAirPlay: AirPlayPolicy.airPlayExtraLatencyFrames
    )
    var destinations: [OutputDestination] = []
    var videoRoutes = VideoRouteRecord()
    var selectedAudioUIDs: Set<String> = []
    var selectedVideoUIDs: Set<String> = []
    var isRunning = false
    var statusMessage = "Ready"
    var lastInstallMessage: String?
    var inputSources: [InputSource] = []
    var selectedInputUIDs: Set<String> = []
    var inputGraph = InputGraph(hardwareInputUIDs: [], applicationInputUIDs: [])
    var showPlayingAppsOnly = false
    var trackManagerSearch = ""
    var visibleGroups: Set<MixerChannelGroup> = Set(MixerChannelGroup.allCases)

    let io = AudioIOCoordinator()
    private let monitor = HALDeviceMonitor()
    private let airPlayBrowser = SessionAirPlayBrowser()
    private var sessionAirPlay: [SessionAirPlayEndpoint] = []
    private var appProcesses: [AppAudioProcess] = []
    private var didSeedDesk = false

    init() {
        monitor.onDevicesChanged = { [weak self] devices in
            Task { @MainActor in
                self?.applyDevices(devices)
            }
        }
        airPlayBrowser.onChange = { [weak self] endpoints in
            Task { @MainActor in
                self?.applySessionAirPlay(endpoints)
            }
        }
    }

    func startMonitoring() {
        if devices.isEmpty {
            applyDevices(HALDeviceEnumerator.enumerateDevices())
        }
        monitor.start()
        airPlayBrowser.start()
        refreshAppProcesses()
    }

    func refresh() {
        applyDevices(HALDeviceEnumerator.enumerateDevices())
        applySessionAirPlay(airPlayBrowser.endpoints)
        refreshAppProcesses()
        statusMessage = "Refreshed \(devices.count) HAL devices, \(inputSources.count) inputs, \(destinations.count) outputs"
    }

    func refreshAppProcesses() {
        appProcesses = HALProcessEnumerator.enumerateProcesses()
        rebuildInputs()
    }

    func applyDevices(_ incoming: [DeviceRecord]) {
        devices = incoming.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        rebuildInputs()
        rebuildDestinations()
        seedDefaultDeskIfEmpty()
    }

    func addInputToMixer(_ source: InputSource) {
        if !strips.contains(where: { $0.uid == source.uid && $0.isInput }) {
            strips.append(InputRouter.inputStrip(for: source, enabled: true, existing: nil))
        }
        setInputEnabled(uid: source.uid, enabled: true)
        statusMessage = "Added input — \(source.name)"
    }

    func addOutputToMixer(_ destination: OutputDestination) {
        if !strips.contains(where: { $0.uid == destination.uid && !$0.isInput }) {
            strips.append(
                MixerStrip(
                    uid: destination.uid,
                    isEnabled: true,
                    gainDecibels: 0,
                    channelMap: MixSource.identityMap(channelCount: max(destination.outputChannelCount, 2)),
                    isInput: false
                )
            )
        }
        setAudioRoute(uid: destination.uid, enabled: true)
        statusMessage = "Added output — \(destination.name)"
    }

    func removeFromMixer(_ strip: MixerStrip) {
        if strip.isInput {
            selectedInputUIDs.remove(strip.uid)
        } else {
            selectedAudioUIDs.remove(strip.uid)
        }
        strips.removeAll { $0.id == strip.id }
        rebuildGraph()
        statusMessage = "Removed from mixer"
    }

    func clearMixer() {
        didSeedDesk = true
        strips = []
        selectedInputUIDs = []
        selectedAudioUIDs = []
        rebuildGraph()
        statusMessage = "Mixer cleared"
    }

    func reassignInput(_ strip: MixerStrip, to source: InputSource) {
        guard strip.isInput, strip.uid != source.uid else { return }
        let next = MixerDesk.transferringControls(
            from: strip,
            onto: InputRouter.inputStrip(for: source, enabled: strip.isEnabled, existing: nil)
        )
        strips.removeAll { $0.id == strip.id }
        selectedInputUIDs.remove(strip.uid)
        strips.append(next)
        setInputEnabled(uid: source.uid, enabled: strip.isEnabled)
        statusMessage = "Assigned input — \(source.name)"
    }

    func reassignOutput(_ strip: MixerStrip, to destination: OutputDestination) {
        guard !strip.isInput, strip.uid != destination.uid else { return }
        let next = MixerDesk.transferringControls(
            from: strip,
            onto: MixerStrip(
                uid: destination.uid,
                isEnabled: strip.isEnabled,
                gainDecibels: strip.gainDecibels,
                channelMap: MixSource.identityMap(channelCount: max(destination.outputChannelCount, 2)),
                isInput: false
            )
        )
        strips.removeAll { $0.id == strip.id }
        selectedAudioUIDs.remove(strip.uid)
        strips.append(next)
        setAudioRoute(uid: destination.uid, enabled: strip.isEnabled)
        statusMessage = "Assigned output — \(destination.name)"
    }

    func setGroupVisible(_ group: MixerChannelGroup, visible: Bool) {
        if visible {
            visibleGroups.insert(group)
        } else {
            visibleGroups.remove(group)
        }
    }

    func setInputEnabled(uid: String, enabled: Bool) {
        if enabled {
            selectedInputUIDs.insert(uid)
            if let source = inputSources.first(where: { $0.uid == uid }),
               !strips.contains(where: { $0.uid == uid && $0.isInput }) {
                strips.append(InputRouter.inputStrip(for: source, enabled: true, existing: nil))
            }
        } else {
            selectedInputUIDs.remove(uid)
        }
        if let index = strips.firstIndex(where: { $0.uid == uid && $0.isInput }) {
            strips[index].isEnabled = enabled
        }
        inputGraph = InputRouter.graph(inputs: inputSources, selectedUIDs: selectedInputUIDs)
        rebuildGraph()
    }

    func applySessionAirPlay(_ endpoints: [SessionAirPlayEndpoint]) {
        sessionAirPlay = endpoints
        rebuildDestinations()
        if !endpoints.isEmpty {
            statusMessage = "Found \(endpoints.count) session AirPlay destination(s)"
        }
    }

    func setAudioRoute(uid: String, enabled: Bool) {
        let result = AudioVideoRouter.applyingAudioSelection(
            destinations: destinations,
            selectedAudioUIDs: selectedAudioUIDs,
            toggling: uid,
            enabled: enabled
        )
        selectedAudioUIDs = result.selected
        if let index = strips.firstIndex(where: { $0.uid == uid && !$0.isInput }) {
            strips[index].isEnabled = enabled
        } else if enabled, let dest = destinations.first(where: { $0.uid == uid }) {
            strips.append(
                MixerStrip(
                    uid: dest.uid,
                    isEnabled: true,
                    gainDecibels: 0,
                    channelMap: MixSource.identityMap(channelCount: max(dest.outputChannelCount, 2)),
                    isInput: false
                )
            )
        }
        rebuildGraph()
    }

    func setVideoRoute(uid: String, enabled: Bool) {
        let result = AudioVideoRouter.applyingVideoSelection(
            destinations: destinations,
            selectedVideoUIDs: selectedVideoUIDs,
            toggling: uid,
            enabled: enabled
        )
        selectedVideoUIDs = result.selected
        videoRoutes = result.record
        let name = destinations.first(where: { $0.uid == uid })?.name ?? uid
        statusMessage = enabled
            ? "Video route on — \(name)"
            : "Video route off — \(name)"
    }

    func setEnabled(_ strip: MixerStrip, enabled: Bool) {
        updateStrip(id: strip.id) { $0.isEnabled = enabled }
        if strip.isInput {
            setInputEnabled(uid: strip.uid, enabled: enabled)
        } else {
            setAudioRoute(uid: strip.uid, enabled: enabled)
        }
    }

    func setGain(_ strip: MixerStrip, decibels: Float) {
        updateStrip(id: strip.id) { $0.gainDecibels = decibels }
    }

    func setMuted(_ strip: MixerStrip, muted: Bool) {
        updateStrip(id: strip.id) { $0.isMuted = muted }
    }

    func setSoloed(_ strip: MixerStrip, soloed: Bool) {
        updateStrip(id: strip.id) { $0.isSoloed = soloed }
    }

    func setPan(_ strip: MixerStrip, pan: Float) {
        updateStrip(id: strip.id) { $0.pan = min(max(pan, -1), 1) }
    }

    func toggleRunning() {
        if isRunning {
            io.stop()
            isRunning = false
            statusMessage = "Mix stopped"
            return
        }
        io.update(devices: devices, strips: strips, inputs: inputSources)
        do {
            try io.start()
            isRunning = io.isRunning
            let registered = io.installedCallbacks.filter(\.procIsShippedAUHALCallback).count
            statusMessage = isRunning
                ? "Mix running — \(registered) AUHAL callback(s) registered"
                : "Mix armed (no HAL units)"
        } catch {
            statusMessage = "Could not start I/O: \(error.localizedDescription)"
        }
    }

    func installLoopbackDevice() {
        switch HALInstaller.install() {
        case .success(let url):
            lastInstallMessage = "Installed \(url.path). Restart coreaudiod or log out to publish the device."
            statusMessage = lastInstallMessage ?? ""
        case .failure(let error):
            lastInstallMessage = error.localizedDescription
            statusMessage = "HAL install blocked: \(error.localizedDescription)"
        }
    }

    func device(for strip: MixerStrip) -> DeviceRecord? {
        devices.first { $0.uid == strip.uid }
    }

    func inputSource(for strip: MixerStrip) -> InputSource? {
        inputSources.first { $0.uid == strip.uid }
    }

    func liveStrip(id: String) -> MixerStrip? {
        strips.first { $0.id == id }
    }

    var hardwareInputSources: [InputSource] { InputCatalog.hardwareInputs(in: inputSources) }
    var applicationInputSources: [InputSource] { InputCatalog.applicationInputs(in: inputSources) }

    var inputStrips: [MixerStrip] { strips.filter(\.isInput) }
    var outputStrips: [MixerStrip] { strips.filter { !$0.isInput } }

    var mixerBanks: [MixerBank] {
        MixerDesk.banks(strips: strips, inputs: inputSources, destinations: destinations)
    }

    var visibleMixerBanks: [MixerBank] {
        MixerDesk.banks(mixerBanks, visibleGroups: visibleGroups)
    }

    func stripsOnMixer(in group: MixerChannelGroup) -> [MixerStrip] {
        MixerDesk.strips(in: group, strips: strips, inputs: inputSources, destinations: destinations)
    }

    var inMixerUIDs: Set<String> { MixerDesk.inMixerUIDs(strips: strips) }

    var availableHardwareInputs: [InputSource] {
        filterSearch(MixerDesk.availableInputs(catalog: hardwareInputSources, inMixer: inMixerUIDs, playingOnly: false))
    }

    var availableApplicationInputs: [InputSource] {
        filterSearch(
            MixerDesk.availableInputs(
                catalog: applicationInputSources,
                inMixer: inMixerUIDs,
                playingOnly: showPlayingAppsOnly
            )
        )
    }

    var availableLocalOutputs: [OutputDestination] {
        filterSearch(MixerDesk.availableOutputs(catalog: catalogOtherOutputs, inMixer: inMixerUIDs, airPlayOnly: false))
    }

    var availableAirPlayOutputs: [OutputDestination] {
        filterSearch(MixerDesk.availableOutputs(catalog: catalogAirPlay, inMixer: inMixerUIDs, airPlayOnly: true))
    }

    private func filterSearch(_ sources: [InputSource]) -> [InputSource] {
        let q = trackManagerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sources }
        return sources.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func filterSearch(_ dests: [OutputDestination]) -> [OutputDestination] {
        let q = trackManagerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return dests }
        return dests.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var airPlayCount: Int {
        destinations.filter(\.isAirPlay).count
    }

    var catalogAirPlay: [OutputDestination] { OutputCatalog.airPlayDestinations(in: destinations) }
    var catalogOtherOutputs: [OutputDestination] { OutputCatalog.otherOutputs(in: destinations) }

    private func updateStrip(id: String, mutate: (inout MixerStrip) -> Void) {
        guard let index = strips.firstIndex(where: { $0.id == id }) else { return }
        mutate(&strips[index])
        rebuildGraph()
    }

    private func rebuildInputs() {
        inputSources = InputCatalog.merge(halDevices: devices, processes: appProcesses)
        let valid = Set(inputSources.map(\.uid))
        strips.removeAll { $0.isInput && !valid.contains($0.uid) }
        selectedInputUIDs = Set(strips.filter { $0.isEnabled && $0.isInput }.map(\.uid))
        inputGraph = InputRouter.graph(inputs: inputSources, selectedUIDs: selectedInputUIDs)
        rebuildGraph()
    }

    private func seedDefaultDeskIfEmpty() {
        guard !didSeedDesk, strips.isEmpty else { return }
        didSeedDesk = true
        if let mic = hardwareInputSources.first(where: { $0.transportName == "Built-in" })
            ?? hardwareInputSources.first {
            addInputToMixer(mic)
        }
        if let speakers = catalogOtherOutputs.first(where: { $0.transportType == kAudioDeviceTransportTypeBuiltIn })
            ?? catalogOtherOutputs.first {
            addOutputToMixer(speakers)
        }
    }

    private func rebuildDestinations() {
        destinations = OutputCatalog.merge(halDevices: devices, sessionAirPlay: sessionAirPlay)
        let valid = Set(destinations.map(\.uid))
        strips.removeAll { !$0.isInput && !valid.contains($0.uid) }
        selectedAudioUIDs = Set(strips.filter { $0.isEnabled && !$0.isInput }.map(\.uid))
        selectedVideoUIDs = selectedVideoUIDs.intersection(Set(destinations.filter(\.supportsVideo).map(\.uid)))
        videoRoutes = AudioVideoRouter.videoRecord(
            destinations: destinations,
            selectedVideoUIDs: selectedVideoUIDs
        )
        rebuildGraph()
    }

    private func rebuildGraph() {
        let enabled = selectedAudioUIDs.union(Set(strips.filter { $0.isEnabled && !$0.isInput }.map(\.uid)))
        selectedAudioUIDs = enabled
        graph = AudioVideoRouter.audioGraph(destinations: destinations, selectedAudioUIDs: enabled)
        let routeDevices = devices + destinations.filter { dest in
            !devices.contains { $0.uid == dest.uid }
        }.map(\.asDeviceRecord)
        io.update(devices: routeDevices, strips: strips, inputs: inputSources)
        let air = graph.isolatedAirPlayUIDs.count
        if air > 0 {
            statusMessage = "Graph updated — \(air) AirPlay destination(s) isolated from the local clock"
        }
    }
}
