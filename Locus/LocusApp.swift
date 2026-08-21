import SwiftUI

@main
struct LocusApp: App {
    @StateObject private var regionService = RegionIdentityService()
    @StateObject private var diagnosticsService = RuntimeDiagnosticsService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(regionService)
                .environmentObject(diagnosticsService)
        }
    }
}
