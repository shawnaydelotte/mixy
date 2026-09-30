import AppKit
import SwiftUI

@main
struct MixyApp: App {
    @State private var controller = MixerController()

    init() {
        _ = DeviceInventory.emitFromLiveHAL()
        if ProcessInfo.processInfo.environment["MIXY_PROBE_TAP"] == "1" {
            let tapResult = DeviceInventory.probeProcessTap()
            fputs("mixy: process-tap probe: \(tapResult)\n", stderr)
            if let path = ProcessInfo.processInfo.environment["MIXY_APP_TAP_PATH"], !path.isEmpty {
                try? tapResult.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        if ProcessInfo.processInfo.environment["MIXY_START_MIX"] == "1" {
            let coordinator = AudioIOCoordinator()
            do {
                let callbacks = try LiveMixStarter.startOnLiveDevices(coordinator)
                LiveMixStarter.emitJSON(callbacks)
                coordinator.stop()
            } catch {
                fputs("mixy: start mix failed: \(error)\n", stderr)
            }
        }
        if ProcessInfo.processInfo.environment["MIXY_QUIT_AFTER_INVENTORY"] == "1" {
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    var body: some Scene {
        Window("Mixy", id: "mixer") {
            MixerView()
                .environment(controller)
                .frame(minWidth: 840, minHeight: 620)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Devices") {
                Button("Refresh Devices") {
                    controller.refresh()
                }
                .keyboardShortcut("r", modifiers: [.command])
                Divider()
                Button("Install Mixy Loopback Device…") {
                    controller.installLoopbackDevice()
                }
            }
            CommandMenu("Mixer") {
                MixerViewCommands(controller: controller)
            }
            CommandMenu("Mix") {
                Button(controller.isRunning ? "Stop Mix" : "Start Mix") {
                    controller.toggleRunning()
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
