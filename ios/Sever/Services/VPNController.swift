import Foundation
import NetworkExtension
import Combine

@MainActor
final class VPNController: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var activeName = ""
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var providerPrefix: String { Bundle.main.bundleIdentifier ?? "dev.sever.vpn" }
    private var providerIDs: [String] { [providerPrefix + ".XrayTunnel", providerPrefix + ".OpenVPNTunnel"] }

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.status = self?.manager?.connection.status ?? .invalid }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func load() async throws {
        let managers: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { values, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: values ?? []) }
            }
        }
        manager = managers.first { providerIDs.contains(($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier ?? "") }
        status = manager?.connection.status ?? .invalid
        activeName = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["displayName"] as? String ?? ""
    }

    func connect(envelope: TunnelEnvelope, name: String) async throws {
        guard status != .connecting, status != .disconnecting else { return }
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= 512 * 1024 else { throw SeverError.message("Конфигурация слишком большая для VPN-расширения") }
        let reference = try SecretStore.write(data, account: "active-tunnel", shared: true)
        if manager == nil { try await load() }
        let manager = self.manager ?? NETunnelProviderManager()
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = providerPrefix + (envelope.engine == .xray ? ".XrayTunnel" : ".OpenVPNTunnel")
        configuration.providerConfiguration = ["displayName": name]
        configuration.serverAddress = "Sever"
        configuration.passwordReference = reference
        configuration.disconnectOnSleep = false
        configuration.includeAllNetworks = true
        configuration.excludeLocalNetworks = false
        configuration.enforceRoutes = true
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "Север"
        manager.isEnabled = true
        let onDemand = NEOnDemandRuleConnect(); onDemand.interfaceTypeMatch = .any
        manager.onDemandRules = [onDemand]
        manager.isOnDemandEnabled = true
        try await save(manager)
        try await reload(manager)
        self.manager = manager
        activeName = name
        try manager.connection.startVPNTunnel()
        status = manager.connection.status
    }

    func disconnect() async throws {
        guard let manager else { return }
        manager.isOnDemandEnabled = false
        try await save(manager)
        manager.connection.stopVPNTunnel()
        status = manager.connection.status
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    private func reload(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    var statusCode: String {
        switch status {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        case .disconnected: return "disconnected"
        default: return "invalid"
        }
    }
    var isActive: Bool { [.connected, .connecting, .reasserting].contains(status) }
}
