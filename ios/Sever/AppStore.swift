import Foundation
import CryptoKit
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var state = SavedState()
    @Published var selectedID: String?
    @Published private(set) var busy = false
    @Published private(set) var checking = false
    @Published private(set) var aiBusy = false
    @Published private(set) var checks: [DiagnosticCheck] = []
    @Published private(set) var explanation = ""
    @Published var message: String?
    private var core: ConfigurationCore?
    private var vault: ProfileVault?
    private var ready = false

    init() {
        do {
            core = try ConfigurationCore()
            vault = try ProfileVault()
            state = try vault!.load()
            selectedID = state.profiles.first?.id
            ready = true
        } catch { message = "Не удалось открыть хранилище профилей. Данные не перезаписаны" }
    }

    var profiles: [ServerProfile] { state.profiles }
    var selected: ServerProfile? { state.profiles.first { $0.id == selectedID } ?? state.profiles.first }

    private func id(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func profiles(_ seeds: [ProfileSeed], source: String) -> [ServerProfile] {
        seeds.enumerated().map { index, seed in
            let title = source == "vpngate" ? ((Locale(identifier: "ru_RU").localizedString(forRegionCode: seed.country) ?? seed.name) + " · \(index + 1)") : seed.name
            return ServerProfile(id: id(source + seed.engine.rawValue + seed.configuration), name: title,
                          engine: seed.engine, configuration: seed.configuration, host: seed.host,
                          port: seed.port, country: seed.country, source: source, nodes: seed.nodes, latency: nil)
        }
    }

    private func persist(_ next: SavedState) throws {
        guard ready, let vault else { throw SeverError.message("Хранилище недоступно") }
        try vault.save(next)
        state = next
        if selectedID == nil || !next.profiles.contains(where: { $0.id == selectedID }) { selectedID = next.profiles.first?.id }
    }

    func importText(_ text: String) throws {
        guard let core else { throw SeverError.message("Обработчик конфигураций недоступен") }
        let seeds: [ProfileSeed] = try core.call("importText", input: text)
        let imported = profiles(seeds, source: "import")
        var next = state
        let existing = Set(next.profiles.map(\.id))
        next.profiles += imported.filter { !existing.contains($0.id) }
        guard next.profiles.count <= 300 else { throw SeverError.message("В первой версии можно сохранить до 300 профилей") }
        try persist(next)
        selectedID = imported.first?.id
    }

    func updateFreeServers() async {
        guard !busy, let core else { return }; busy = true; defer { busy = false }
        do {
            let url = URL(string: "https://www.vpngate.net/api/iphone/")!
            let data = try await HTTPClient.fetch(url)
            guard let text = String(data: data, encoding: .utf8) else { throw SeverError.message("Каталог вернул неизвестную кодировку") }
            let seeds: [ProfileSeed] = try core.call("vpnGate", input: text)
            var next = state
            next.profiles = state.profiles.filter { $0.source != "vpngate" } + profiles(seeds, source: "vpngate")
            next.feedUpdatedAt = Date()
            try persist(next)
        } catch { message = "Не удалось обновить VPN Gate. Сохранённый список оставлен без изменений" }
    }

    func addSubscription(_ text: String) async throws {
        guard !busy, let core, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" else {
            throw SeverError.message("Введите HTTPS-ссылку подписки")
        }
        busy = true; defer { busy = false }
        let data = try await HTTPClient.fetch(url)
        guard let text = String(data: data, encoding: .utf8) else { throw SeverError.message("Подписка вернула неизвестную кодировку") }
        let seeds: [ProfileSeed] = try core.call("importText", input: text)
        let sourceID = id(url.absoluteString)
        var next = state
        next.profiles = state.profiles.filter { $0.source != sourceID } + profiles(seeds, source: sourceID)
        next.subscriptions.removeAll { $0.id == sourceID }
        next.subscriptions.append(SubscriptionSource(id: sourceID, url: url, updatedAt: Date()))
        try persist(next)
    }

    func refreshIfNeeded() async {
        if state.feedUpdatedAt == nil || Date().timeIntervalSince(state.feedUpdatedAt!) > 3600 { await updateFreeServers() }
        for source in state.subscriptions where Date().timeIntervalSince(source.updatedAt) > 3600 {
            do { try await addSubscription(source.url.absoluteString) }
            catch { message = "Не удалось обновить одну из подписок. Сохранённые профили доступны" }
        }
    }

    func chooseFastest() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let candidates = Array(profiles.filter { !$0.host.isEmpty && $0.port > 0 }.prefix(12))
        var measured: [String: Int] = [:]
        for start in stride(from: 0, to: candidates.count, by: 4) {
            let batch = candidates[start..<min(start + 4, candidates.count)]
            await withTaskGroup(of: (String, Int?).self) { group in
                for profile in batch { group.addTask { (profile.id, await ConnectionChecks.tcp(host: profile.host, port: profile.port)) } }
                for await (identifier, delay) in group { if let delay { measured[identifier] = delay } }
            }
        }
        var next = state
        for index in next.profiles.indices where candidates.contains(where: { $0.id == next.profiles[index].id }) { next.profiles[index].latency = measured[next.profiles[index].id] }
        if let winner = measured.min(by: { $0.value < $1.value }) { selectedID = winner.key }
        else { message = "Доступные TCP-узлы не найдены. Попробуйте обновить каталог или импортировать профиль" }
        do { try persist(next) } catch { message = "Не удалось сохранить результаты проверки" }
    }

    func envelope() throws -> TunnelEnvelope {
        guard let profile = selected, let core else { throw SeverError.message("Сначала добавьте сервер") }
        let pool: [ServerProfile]
        if profile.engine == .openvpn {
            let rest = profiles.filter { $0.engine == .openvpn && $0.id != profile.id && $0.source == profile.source }
                .sorted { ($0.latency ?? Int.max) < ($1.latency ?? Int.max) }
            pool = [profile] + Array(rest.prefix(2))
        } else { pool = [profile] }
        let candidates = try pool.map { server -> TunnelCandidate in
            let configuration: String = server.engine == .xray ? try core.call("strictXray", input: server.configuration) : server.configuration
            return TunnelCandidate(configuration: configuration,
                                   username: server.source == "vpngate" ? "vpn" : nil,
                                   password: server.source == "vpngate" ? "vpn" : nil)
        }
        return TunnelEnvelope(version: 1, engine: profile.engine, candidates: candidates)
    }

    func diagnose() async {
        guard !checking else { return }; checking = true; explanation = ""; defer { checking = false }
        checks = await ConnectionChecks.internet()
    }

    func askAI(tunnelStatus: String) async {
        guard !aiBusy, !checks.isEmpty, let core else { return }
        aiBusy = true; defer { aiBusy = false }
        do {
            let report = DiagnosticReport(tunnel: tunnelStatus, engine: selected?.engine.rawValue, checks: checks)
            let data = try JSONEncoder().encode(report)
            let object = try JSONSerialization.jsonObject(with: data)
            let safe: SafeReport = try core.call("safeDiagnostic", input: object)
            let safeJSON = String(data: try JSONEncoder().encode(safe), encoding: .utf8)!
            explanation = try await AIClient.explain(safeReport: safeJSON, settings: AISettings.load())
        } catch let error as SeverError { message = error.localizedDescription }
        catch { message = "Не удалось получить ответ ИИ. Проверьте доступность сервиса и настройки API" }
    }
}

private struct SafeReport: Codable {
    let version: Int
    let tunnel: String
    let engine: String?
    let checks: [DiagnosticCheck]
}
