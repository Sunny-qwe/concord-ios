import SwiftUI

// Concord iOS — main app entry point.
// Scaffold only: UI skeleton + placeholder stores. No real proxy traffic yet.
// TODO: wire ContentView to the real Concord engine state (see ProxyStore /
// ConfigStore) once the Rust staticlib integration is defined.

@main
struct ConcordiOSApp: App {
    @StateObject private var proxyStore = ProxyStore()
    @StateObject private var configStore = ConfigStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(proxyStore)
                .environmentObject(configStore)
        }
    }
}
