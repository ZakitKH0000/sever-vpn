import SwiftUI

@main
@MainActor
struct SeverApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var vpn = VPNController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(vpn)
                .preferredColorScheme(.dark)
                .tint(SeverStyle.accent)
                .task {
                    do { try await vpn.load() } catch { store.message = "Не удалось прочитать состояние VPN" }
                    await store.refreshIfNeeded()
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { Task { await store.refreshIfNeeded() } }
                }
        }
    }
}
