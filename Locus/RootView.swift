import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            RegionIdentityView()
                .tabItem { Label("Region", systemImage: "globe.asia.australia.fill") }

            RuntimeDiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }

        }
    }
}
