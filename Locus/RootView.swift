import SwiftUI

struct RootView: View {
    @EnvironmentObject private var regionService: RegionIdentityService

    var body: some View {
        TabView {
            RegionIdentityView()
                .tabItem { Label("Region", systemImage: "globe.asia.australia.fill") }

            RuntimeDiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }

            CoreTextGB18030View()
                .tabItem { Label("CoreText", systemImage: "textformat") }
        }
        .overlay {
            if regionService.shouldRespring {
                RespringOverlay()
            }
        }
    }
}
