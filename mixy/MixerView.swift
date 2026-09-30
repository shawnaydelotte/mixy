import SwiftUI

struct MixerView: View {
    @Environment(MixerController.self) private var controller

    var body: some View {
        NavigationSplitView {
            TrackManagerView()
                .navigationSplitViewColumnWidth(min: 248, ideal: 292, max: 380)
        } detail: {
            VStack(spacing: 0) {
                MixerConsole()
                StatusBar()
            }
            .background(MixerPalette.console)
        }
        .navigationTitle("Mixy")
        .toolbarBackground(MixerPalette.chrome, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    controller.toggleRunning()
                } label: {
                    Label(
                        controller.isRunning ? "Stop Mix" : "Start Mix",
                        systemImage: controller.isRunning ? "stop.fill" : "play.fill"
                    )
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
            ToolbarItem(placement: .automatic) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    controller.refresh()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            ToolbarItem(placement: .automatic) {
                AddChannelMenus(controller: controller)
            }
        }
        .onAppear {
            controller.startMonitoring()
        }
    }
}

/// Logic/Reaper-style add menus — pick what sits on the desk.
struct AddChannelMenus: View {
    var controller: MixerController

    var body: some View {
        Menu {
            MixerAddChannelContent(controller: controller)
            Divider()
            Button("Clear Mixer", role: .destructive) {
                controller.clearMixer()
            }
        } label: {
            Label("Add Channel", systemImage: "plus")
        }
        .accessibilityIdentifier("add-channel-menu")
    }
}

/// Shared add-channel items for the toolbar menu and the Mixer command menu.
struct MixerAddChannelContent: View {
    var controller: MixerController

    var body: some View {
        Menu(MixerChrome.addSectionTitle(.hardwareInputs)) {
            if controller.availableHardwareInputs.isEmpty {
                Text("All hardware inputs are on the mixer").foregroundStyle(.secondary)
            }
            ForEach(controller.availableHardwareInputs) { source in
                Button("\(source.name)  (\(MixerChrome.channelCountLabel(source.inputChannelCount)))") {
                    controller.addInputToMixer(source)
                }
            }
        }
        Menu(MixerChrome.addSectionTitle(.applicationInputs)) {
            if let allApps = controller.availableApplicationInputs.first(where: { $0.kind == .systemWideAppTap }) {
                Button("All Application Audio") {
                    controller.addInputToMixer(allApps)
                }
                Divider()
            }
            Toggle("Playing Apps Only", isOn: Binding(
                get: { controller.showPlayingAppsOnly },
                set: { controller.showPlayingAppsOnly = $0 }
            ))
            Divider()
            let apps = controller.availableApplicationInputs.filter { $0.kind == .application }
            if apps.isEmpty {
                Text("No more applications to add").foregroundStyle(.secondary)
            }
            ForEach(apps) { source in
                Button(source.name + (source.isRunningOutput ? "  ●" : "")) {
                    controller.addInputToMixer(source)
                }
            }
        }
        Menu(MixerChrome.addSectionTitle(.localOutputs)) {
            if controller.availableLocalOutputs.isEmpty {
                Text("All local outputs are on the mixer").foregroundStyle(.secondary)
            }
            ForEach(controller.availableLocalOutputs) { dest in
                Button("\(dest.name)  (\(dest.kindLabel))") {
                    controller.addOutputToMixer(dest)
                }
            }
        }
        Menu(MixerChrome.addSectionTitle(.airPlay)) {
            if controller.availableAirPlayOutputs.isEmpty {
                Text("No additional AirPlay destinations").foregroundStyle(.secondary)
            }
            ForEach(controller.availableAirPlayOutputs) { dest in
                Button(dest.name) {
                    controller.addOutputToMixer(dest)
                }
            }
        }
    }
}

struct MixerViewCommands: View {
    var controller: MixerController

    var body: some View {
        MixerAddChannelContent(controller: controller)
        Divider()
        Menu("View") {
            ForEach(MixerChannelGroup.allCases) { group in
                Toggle(group.rawValue, isOn: Binding(
                    get: { controller.visibleGroups.contains(group) },
                    set: { controller.setGroupVisible(group, visible: $0) }
                ))
            }
        }
        Divider()
        Toggle("Playing Apps Only", isOn: Binding(
            get: { controller.showPlayingAppsOnly },
            set: { controller.showPlayingAppsOnly = $0 }
        ))
        Button("Clear Mixer", role: .destructive) {
            controller.clearMixer()
        }
    }
}

private enum MixerPalette {
    static let console = Color(MixerColorToken(red: 0.09, green: 0.10, blue: 0.11))
    static let chrome = Color(MixerColorToken(red: 0.12, green: 0.13, blue: 0.14))
    static let strip = Color(MixerColorToken(red: 0.16, green: 0.17, blue: 0.185))
    static let stripWell = Color(MixerColorToken(red: 0.08, green: 0.085, blue: 0.09))
    static let stripEdge = Color.white.opacity(0.08)
    static let bankPlate = Color(MixerColorToken(red: 0.12, green: 0.125, blue: 0.135))
    static let faderTrack = Color.black.opacity(0.55)
    static let faderCap = Color(MixerColorToken(red: 0.86, green: 0.86, blue: 0.83))
    static let sidebar = Color(MixerColorToken(red: 0.11, green: 0.12, blue: 0.13))
}

private extension Color {
    init(_ token: MixerColorToken) {
        self.init(red: token.red, green: token.green, blue: token.blue, opacity: token.opacity)
    }
}

private struct MixerConsole: View {
    @Environment(MixerController.self) private var controller

    var body: some View {
        VStack(spacing: 0) {
            MixerViewFilterBar(controller: controller)
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .bottom, spacing: 0) {
                    if controller.strips.isEmpty {
                        ConsolePlaceholder(copy: MixerChrome.emptyDeskCopy())
                    } else if controller.visibleMixerBanks.isEmpty {
                        ConsolePlaceholder(copy: MixerChrome.hiddenGroupsCopy())
                    } else {
                        ForEach(Array(controller.visibleMixerBanks.enumerated()), id: \.element.id) { index, bank in
                            if index > 0 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.08))
                                    .frame(width: 1)
                                    .padding(.vertical, 18)
                            }
                            stripBank(bank)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func stripBank(_ bank: MixerBank) -> some View {
        let accent = Color(MixerChrome.groupAccent(bank.group))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(accent)
                    .frame(width: 3, height: 12)
                Text(MixerChrome.bankTitle(bank.group))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.3)
                    .foregroundStyle(accent)
                Text("\(bank.strips.count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .padding(.leading, 4)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(bank.strips) { strip in
                    ChannelStripView(strip: strip, group: bank.group)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(MixerPalette.bankPlate, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct ConsolePlaceholder: View {
    let copy: MixerDeskCopy

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: copy.systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text(copy.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(copy.detail)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(minWidth: 460, minHeight: 420)
    }
}

private struct ChannelStripView: View {
    @Environment(MixerController.self) private var controller
    let strip: MixerStrip
    let group: MixerChannelGroup

    private var live: MixerStrip {
        controller.liveStrip(id: strip.id) ?? strip
    }

    var body: some View {
        let live = live
        let device = controller.device(for: live)
        let kind = device.map(DeviceClassifier.classify) ?? fallbackKind
        let channels = channelCount(device)
        let title = controller.inputSource(for: live)?.name
            ?? controller.destinations.first(where: { $0.uid == live.uid })?.name
            ?? device?.name
            ?? live.uid
        let mute = MixerChrome.muteChrome(isMuted: live.isMuted)
        let solo = MixerChrome.soloChrome(isSoloed: live.isSoloed)
        let power = MixerChrome.enabledChrome(isEnabled: live.isEnabled)
        let accent = Color(MixerChrome.groupAccent(group))
        VStack(spacing: 7) {
            Rectangle()
                .fill(accent)
                .frame(height: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))

            StripIOAssignmentMenu(strip: live, title: title)

            HStack(spacing: 4) {
                chromeBadge(MixerChrome.roleLabel(isInput: strip.isInput), color: accent)
                chromeBadge(MixerChrome.kindBadgeLabel(kind), color: Color(MixerChrome.kindToken(kind)))
            }
            Text(MixerChrome.channelCountLabel(channels))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))

            if let source = controller.inputSource(for: live),
               let badge = MixerChrome.applicationBadgeLabel(kind: source.kind) {
                Label(badge, systemImage: "app.badge")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(MixerColorToken.application))
            }
            if kind == .airPlay {
                Label("AirPlay", systemImage: "airplayaudio")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(MixerColorToken.airPlay))
                    .labelStyle(.titleAndIcon)
            }

            VStack(spacing: 3) {
                Text(MixerChrome.panLabel(live.pan))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(MixerPalette.stripWell, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                Slider(
                    value: Binding(
                        get: { Double(self.live.pan) },
                        set: { controller.setPan(self.live, pan: Float($0)) }
                    ),
                    in: -1...1
                )
                .controlSize(.mini)
                .tint(accent)
                HStack {
                    Text("L")
                    Spacer()
                    Text("R")
                }
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.32))
            }
            .padding(.horizontal, 2)

            HStack(spacing: 4) {
                MixerPadButton(chrome: solo) {
                    controller.setSoloed(self.live, soloed: !self.live.isSoloed)
                }
                MixerPadButton(chrome: mute) {
                    controller.setMuted(self.live, muted: !self.live.isMuted)
                }
            }

            VerticalFader(
                value: Binding(
                    get: { Double(self.live.gainDecibels) },
                    set: { controller.setGain(self.live, decibels: Float($0)) }
                ),
                range: -96...12
            )
            .frame(height: 208)

            Text(MixerChrome.gainLabel(live.gainDecibels))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(MixerPalette.stripWell, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            MixerPadButton(chrome: power) {
                controller.setEnabled(self.live, enabled: !self.live.isEnabled)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .padding(.top, 6)
        .frame(width: 108)
        .background(MixerPalette.strip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(kind == .airPlay ? Color(MixerColorToken.airPlay).opacity(0.55) : MixerPalette.stripEdge, lineWidth: 1)
        }
        .opacity(MixerChrome.stripOpacity(isMuted: live.isMuted, isEnabled: live.isEnabled))
        .contextMenu {
            StripIOAssignmentMenu(strip: live, title: "Change I/O", asContextMenu: true)
            Divider()
            Button("Remove from Mixer", role: .destructive) {
                controller.removeFromMixer(self.live)
            }
        }
    }

    private var fallbackKind: DeviceKind {
        if group == .airPlay { return .airPlay }
        return .local
    }

    private func chromeBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.22), in: Capsule())
            .foregroundStyle(color)
    }

    private func channelCount(_ device: DeviceRecord?) -> Int {
        if let source = controller.inputSource(for: live), source.isApplicationAudio {
            return source.inputChannelCount
        }
        if let dest = controller.destinations.first(where: { $0.uid == live.uid }) {
            return dest.outputChannelCount
        }
        guard let device else { return live.channelMap.count }
        return live.isInput ? device.inputChannelCount : device.outputChannelCount
    }
}

private struct MixerViewFilterBar: View {
    var controller: MixerController

    var body: some View {
        HStack(spacing: 8) {
            Text("VIEW")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.38))
            ForEach(MixerChannelGroup.allCases) { group in
                let on = controller.visibleGroups.contains(group)
                let accent = Color(MixerChrome.groupAccent(group))
                Button {
                    controller.setGroupVisible(group, visible: !on)
                } label: {
                    Label(group.rawValue, systemImage: group.systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .foregroundStyle(on ? Color.white : Color.white.opacity(0.42))
                        .background(
                            on ? accent.opacity(0.28) : Color.white.opacity(0.05),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .strokeBorder(on ? accent.opacity(0.65) : Color.white.opacity(0.06), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("view-group-\(group.rawValue)")
            }
            Spacer()
            Text("\(controller.strips.count) ch")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(MixerPalette.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
        .accessibilityIdentifier("mixer-view-filter")
    }
}

private struct MixerPadButton: View {
    let chrome: MixerControlChrome
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(chrome.label)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 24)
                .foregroundStyle(Color(chrome.text))
                .background(Color(chrome.fill), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(chrome.isLit ? 0.28 : 0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chrome.label)
        .accessibilityAddTraits(chrome.isLit ? .isSelected : [])
    }
}

private struct VerticalFader: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let width = geo.size.width
            let t = MixerChrome.faderNormalized(value: value, range: range)
            let y = (1 - t) * height
            ZStack(alignment: .top) {
                ForEach(MixerChrome.faderTickDecibels, id: \.self) { tick in
                    let ty = (1 - MixerChrome.faderNormalized(value: tick, range: range)) * height
                    HStack(spacing: 3) {
                        Rectangle()
                            .fill(Color.white.opacity(tick == 0 ? 0.35 : 0.14))
                            .frame(width: tick == 0 ? 10 : 6, height: 1)
                        if tick == 0 || tick == 12 || tick == -24 {
                            Text(tick == 12 ? "+12" : "\(Int(tick))")
                                .font(.system(size: 7, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.28))
                        }
                    }
                    .position(x: 18, y: ty)
                }
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(MixerPalette.faderTrack)
                    .frame(width: 6)
                    .frame(maxHeight: .infinity)
                    .position(x: width / 2 + 8, y: height / 2)
                Capsule()
                    .fill(MixerPalette.faderCap)
                    .frame(width: 28, height: 14)
                    .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
                    .position(x: width / 2 + 8, y: min(max(y, 7), height - 7))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clampedY = min(max(drag.location.y, 0), height)
                        let newT = 1 - Double(clampedY / max(height, 1))
                        value = range.lowerBound + newT * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(width: 52)
        .accessibilityLabel("Fader")
        .accessibilityValue(Text(MixerChrome.gainLabel(Float(value))))
    }
}

/// Logic-style I/O slot: assign or swap the source/destination on an included strip.
private struct StripIOAssignmentMenu: View {
    @Environment(MixerController.self) private var controller
    let strip: MixerStrip
    let title: String
    var asContextMenu: Bool = false

    var body: some View {
        Menu {
            if strip.isInput {
                inputChoices
            } else {
                outputChoices
            }
        } label: {
            if asContextMenu {
                Text(title)
            } else {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .center)
                    .padding(.horizontal, 4)
                    .background(MixerPalette.stripWell, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(asContextMenu ? .automatic : .hidden)
        .help(strip.isInput ? "Assign input" : "Assign output")
        .accessibilityIdentifier("io-assign-\(strip.id)")
    }

    @ViewBuilder
    private var inputChoices: some View {
        let current = controller.inputSource(for: strip)
        let hardware = assignmentHardwareInputs(current: current)
        let apps = assignmentApplicationInputs(current: current)
        if !hardware.isEmpty {
            Section(MixerChannelGroup.hardwareInputs.rawValue) {
                ForEach(hardware) { source in
                    Button {
                        controller.reassignInput(strip, to: source)
                    } label: {
                        assignmentLabel(source.name, selected: source.uid == strip.uid)
                    }
                }
            }
        }
        if !apps.isEmpty {
            Section(MixerChannelGroup.applicationInputs.rawValue) {
                ForEach(apps) { source in
                    Button {
                        controller.reassignInput(strip, to: source)
                    } label: {
                        assignmentLabel(
                            source.name + (source.isRunningOutput ? "  ●" : ""),
                            selected: source.uid == strip.uid
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var outputChoices: some View {
        let current = controller.destinations.first(where: { $0.uid == strip.uid })
        let local = assignmentLocalOutputs(current: current)
        let air = assignmentAirPlayOutputs(current: current)
        if !local.isEmpty {
            Section(MixerChannelGroup.localOutputs.rawValue) {
                ForEach(local) { dest in
                    Button {
                        controller.reassignOutput(strip, to: dest)
                    } label: {
                        assignmentLabel("\(dest.name)  (\(dest.kindLabel))", selected: dest.uid == strip.uid)
                    }
                }
            }
        }
        if !air.isEmpty {
            Section(MixerChannelGroup.airPlay.rawValue) {
                ForEach(air) { dest in
                    Button {
                        controller.reassignOutput(strip, to: dest)
                    } label: {
                        assignmentLabel(dest.name, selected: dest.uid == strip.uid)
                    }
                }
            }
        }
    }

    private func assignmentLabel(_ name: String, selected: Bool) -> some View {
        HStack {
            Text(name)
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func assignmentHardwareInputs(current: InputSource?) -> [InputSource] {
        var items = controller.availableHardwareInputs
        if let current, current.isHardware, !items.contains(where: { $0.uid == current.uid }) {
            items.insert(current, at: 0)
        }
        return items
    }

    private func assignmentApplicationInputs(current: InputSource?) -> [InputSource] {
        var items = controller.availableApplicationInputs
        if let current, current.isApplicationAudio, !items.contains(where: { $0.uid == current.uid }) {
            items.insert(current, at: 0)
        }
        return items
    }

    private func assignmentLocalOutputs(current: OutputDestination?) -> [OutputDestination] {
        var items = controller.availableLocalOutputs
        if let current, !current.isAirPlay, !items.contains(where: { $0.uid == current.uid }) {
            items.insert(current, at: 0)
        }
        return items
    }

    private func assignmentAirPlayOutputs(current: OutputDestination?) -> [OutputDestination] {
        var items = controller.availableAirPlayOutputs
        if let current, current.isAirPlay, !items.contains(where: { $0.uid == current.uid }) {
            items.insert(current, at: 0)
        }
        return items
    }
}

/// Reaper/Logic track manager: included tracks first, then grouped catalogs to add.
private struct TrackManagerView: View {
    @Environment(MixerController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        List {
            Section {
                TextField("Filter sources", text: $controller.trackManagerSearch)
                    .textFieldStyle(.roundedBorder)
                Toggle("Playing apps only", isOn: $controller.showPlayingAppsOnly)
                    .font(.caption)
            }

            ForEach(MixerChannelGroup.allCases) { group in
                onMixerSection(group)
            }

            catalogSection(
                title: MixerChrome.addSectionTitle(.hardwareInputs),
                systemImage: MixerChannelGroup.hardwareInputs.systemImage,
                accent: MixerChrome.groupAccent(.hardwareInputs),
                sources: controller.availableHardwareInputs
            )
            catalogSection(
                title: MixerChrome.addSectionTitle(.applicationInputs),
                systemImage: MixerChannelGroup.applicationInputs.systemImage,
                accent: MixerChrome.groupAccent(.applicationInputs),
                sources: controller.availableApplicationInputs
            )
            outputSection(
                title: MixerChrome.addSectionTitle(.localOutputs),
                systemImage: MixerChannelGroup.localOutputs.systemImage,
                accent: MixerChrome.groupAccent(.localOutputs),
                destinations: controller.availableLocalOutputs
            )
            outputSection(
                title: MixerChrome.addSectionTitle(.airPlay),
                systemImage: MixerChannelGroup.airPlay.systemImage,
                accent: MixerChrome.groupAccent(.airPlay),
                destinations: controller.availableAirPlayOutputs
            )
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(MixerPalette.sidebar)
        .navigationTitle("Track Manager")
        .accessibilityIdentifier("track-manager")
        .accessibilityIdentifier("input-sources-panel")
        .accessibilityIdentifier("output-routing-panel")
    }

    @ViewBuilder
    private func onMixerSection(_ group: MixerChannelGroup) -> some View {
        let members = controller.stripsOnMixer(in: group)
        if !members.isEmpty {
            Section(MixerChrome.onMixerSectionTitle(group)) {
                ForEach(members) { strip in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(MixerChrome.groupAccent(group)))
                            .frame(width: 7, height: 7)
                        Image(systemName: group.systemImage)
                            .foregroundStyle(Color(MixerChrome.groupAccent(group)))
                        Text(stripLabel(strip))
                            .lineLimit(1)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            controller.removeFromMixer(strip)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .listRowBackground(Color.white.opacity(0.04))
                    .accessibilityIdentifier("on-mixer-\(strip.id)")
                }
            }
        }
    }

    @ViewBuilder
    private func catalogSection(
        title: String,
        systemImage: String,
        accent: MixerColorToken,
        sources: [InputSource]
    ) -> some View {
        Section(title) {
            if sources.isEmpty {
                Text(MixerChrome.emptyCatalogCopy())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(sources) { source in
                Button {
                    controller.addInputToMixer(source)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.name)
                            Text(source.isHardware
                                 ? "\(source.transportName) · \(MixerChrome.channelCountLabel(source.inputChannelCount))"
                                 : (source.isRunningOutput ? "Playing · app audio" : "App audio"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: systemImage)
                            .foregroundStyle(Color(accent))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("input-source-\(source.uid)")
            }
        }
    }

    @ViewBuilder
    private func outputSection(
        title: String,
        systemImage: String,
        accent: MixerColorToken,
        destinations: [OutputDestination]
    ) -> some View {
        Section(title) {
            if destinations.isEmpty {
                Text(MixerChrome.emptyCatalogCopy())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(destinations) { dest in
                HStack {
                    Button {
                        controller.addOutputToMixer(dest)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(dest.name)
                                Text(dest.isAirPlay ? "AirPlay" : dest.kindLabel)
                                    .font(.caption)
                                    .foregroundStyle(dest.isAirPlay ? Color(MixerColorToken.airPlay) : .secondary)
                            }
                        } icon: {
                            Image(systemName: systemImage)
                                .foregroundStyle(Color(accent))
                        }
                    }
                    .buttonStyle(.plain)
                    if dest.supportsVideo {
                        Toggle("Video", isOn: Binding(
                            get: { controller.selectedVideoUIDs.contains(dest.uid) },
                            set: { controller.setVideoRoute(uid: dest.uid, enabled: $0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help("Route video")
                    }
                }
                .accessibilityIdentifier("output-route-\(dest.uid)")
            }
        }
    }

    private func stripLabel(_ strip: MixerStrip) -> String {
        controller.inputSource(for: strip)?.name
            ?? controller.destinations.first(where: { $0.uid == strip.uid })?.name
            ?? strip.uid
    }
}

private struct StatusBar: View {
    @Environment(MixerController.self) private var controller

    var body: some View {
        HStack(spacing: 14) {
            statusChip("\(controller.strips.count) on desk", systemImage: "slider.vertical.3")
            statusChip(
                "\(controller.graph.localClockDeviceUIDs.count) local clock",
                systemImage: "metronome"
            )
            statusChip(
                "\(controller.graph.isolatedAirPlayUIDs.count) AirPlay isolated",
                systemImage: "airplayaudio"
            )
            statusChip(
                "\(controller.airPlayCount) AirPlay present",
                systemImage: "wifi"
            )
            statusChip(
                "\(controller.videoRoutes.selectedUIDs.count) video route(s)",
                systemImage: "tv"
            )
            Spacer()
            Text(controller.statusMessage)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.72))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(MixerPalette.chrome)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }

    private func statusChip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.05), in: Capsule())
    }
}

#Preview {
    MixerView()
        .environment(MixerController())
        .frame(width: 1100, height: 720)
}
