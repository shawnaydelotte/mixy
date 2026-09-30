import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Form {
                Section("Buffers") {
                    LabeledContent("Local buffer") {
                        Text("\(AirPlayPolicy.localBufferFrames) frames")
                    }
                    LabeledContent("AirPlay buffer") {
                        Text("\(AirPlayPolicy.airPlayBufferFrames) frames")
                    }
                    LabeledContent("AirPlay extra latency") {
                        Text("\(AirPlayPolicy.airPlayExtraLatencyFrames) frames")
                    }
                }
                Section {
                    Text("AirPlay destinations never join a Core Audio aggregate with local or music-interface devices.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Mixing", systemImage: "slider.horizontal.3") }

            Form {
                Section("Loopback") {
                    LabeledContent("Virtual device") {
                        Text("Mixy Loopback")
                    }
                    LabeledContent("Mechanism") {
                        Text("Audio Server Plug-in")
                    }
                    LabeledContent("Install path") {
                        Text(HALInstaller.systemDriverURL.path)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Installed") {
                        Text(HALInstaller.isInstalled ? "Yes" : "No")
                    }
                }
                Section {
                    Text("Audio Server Plug-in is Apple’s documented path for a virtual loopback device. AudioDriverKit is not used.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Loopback", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 480, height: 320)
    }
}
