import Foundation
import NetworkExtension
import Combine

@MainActor
final class VPNController: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var activeName = ""
    @Published private(set) var phase = ""
    @Published private(set) var lastError: String?
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var providerPrefix: String { Bundle.main.bundleIdentifier ?? "dev.sever.vpn" }
    private var legacyProviderIDs: [String] { [providerPrefix + ".XrayTunnel", providerPrefix + ".OpenVPNTunnel"] }
    private var deliberatelyStopped = false

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.statusDidChange() }
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
        let identifiers = (try? TunnelPlugins.installed().map(\.identifier)) ?? []
        manager = managers.first {
            guard let protocolInfo = $0.protocolConfiguration as? NETunnelProviderProtocol else { return false }
            return identifiers.contains(protocolInfo.providerBundleIdentifier ?? "") ||
                legacyProviderIDs.contains(protocolInfo.providerBundleIdentifier ?? "") ||
                protocolInfo.providerConfiguration?["dev.sever.managed"] as? Bool == true
        }
        status = manager?.connection.status ?? .invalid
        activeName = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["displayName"] as? String ?? ""
    }

    func connect(envelope: TunnelEnvelope, name: String) async throws {
        guard status != .connecting, status != .disconnecting else { return }
        lastError = nil; deliberatelyStopped = false
        phase = "Проверяем установленное VPN-расширение"
        let providerID: String
        do { providerID = try TunnelPlugins.identifier(for: envelope.engine, in: TunnelPlugins.installed()) }
        catch { phase = "Расширение не найдено"; lastError = VPNFailure.text(error); throw error }
        phase = "Передаём конфигурацию в защищённое хранилище"
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= 512 * 1024 else { throw SeverError.message("Конфигурация слишком большая для VPN-расширения") }
        let reference: Data
        do { reference = try SecretStore.write(data, account: "active-tunnel", shared: true) }
        catch { lastError = VPNFailure.text(error); throw error }
        if manager == nil { try await load() }
        let manager = self.manager ?? NETunnelProviderManager()
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = providerID
        configuration.providerConfiguration = ["displayName": name, "dev.sever.managed": true]
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
        phase = "Сохраняем профиль VPN и ожидаем разрешение iOS"
        do { try await save(manager); try await reload(manager) }
        catch {
            lastError = "Не удалось сохранить профиль VPN. " + VPNFailure.text(error)
            throw SeverError.message(lastError!)
        }
        self.manager = manager
        activeName = name
        phase = "iOS запускает VPN-расширение"
        do { try manager.connection.startVPNTunnel() }
        catch {
            lastError = "iOS не запустила VPN-расширение. " + VPNFailure.text(error)
            throw SeverError.message(lastError!)
        }
        status = manager.connection.status
    }

    func disconnect() async throws {
        guard let manager else { return }
        deliberatelyStopped = true
        manager.isOnDemandEnabled = false
        try await save(manager)
        manager.connection.stopVPNTunnel()
        status = manager.connection.status
        phase = "Отключение по вашей команде"
    }

    private func statusDidChange() {
        let previous = status
        status = manager?.connection.status ?? .invalid
        switch status {
        case .connected: phase = "VPN-расширение сообщило о подключении"; lastError = nil
        case .connecting: phase = "iOS запускает расширение и устанавливает соединение"
        case .reasserting: phase = "VPN-расширение восстанавливает соединение"
        case .disconnected, .invalid:
            if !deliberatelyStopped && [.connecting, .connected, .reasserting].contains(previous) {
                phase = "Соединение завершилось"
                Task { await readLastError() }
            }
        default: break
        }
    }

    func readLastError() async {
        guard let connection = manager?.connection, !deliberatelyStopped else { return }
        let error: Error? = await withCheckedContinuation { continuation in
            connection.fetchLastDisconnectError { continuation.resume(returning: $0) }
        }
        guard manager?.connection === connection, !deliberatelyStopped else { return }
        if let error { lastError = VPNFailure.text(error) }
        else if status == .disconnected { lastError = "iOS не передала причину отключения. Последний этап: " + phase }
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
