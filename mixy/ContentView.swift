import SwiftUI

/// Kept so the original template file continues to compile; the mixer is the real UI.
struct ContentView: View {
    @State private var controller = MixerController()

    var body: some View {
        MixerView()
            .environment(controller)
    }
}
