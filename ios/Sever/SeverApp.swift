import SwiftUI

@main
@MainActor
struct SeverApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var vpn = VPNController()
    @Environment(\.scenePhase) private var scenePhase
    private var isTesting: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(vpn)
                .preferredColorScheme(.dark)
                .tint(SeverStyle.accent)
                .task {
                    guard !isTesting else { return }
                    do { try await vpn.load() } catch { store.message = "Не удалось прочитать состояние VPN" }
                    await store.refreshIfNeeded()
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active && !isTesting { Task { await store.refreshIfNeeded() } }
                }
        }
    }
}
