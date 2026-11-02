import Foundation

struct TunnelPlugin: Equatable {
    let identifier: String
    let engine: TunnelEngine

    init?(info: [String: Any]) {
        guard let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              let extensionInfo = info["NSExtension"] as? [String: Any],
              extensionInfo["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel" else { return nil }
        let explicit = (info["SeverTunnelEngine"] as? String).flatMap(TunnelEngine.init(rawValue:))
        let executable = (info["CFBundleExecutable"] as? String ?? "").lowercased()
        if let explicit { engine = explicit }
        else if executable.contains("openvpn") { engine = .openvpn }
        else if executable.contains("xray") { engine = .xray }
        else { return nil }
        self.identifier = identifier
    }
}

enum TunnelPlugins {
    static func installed(in directory: URL? = Bundle.main.builtInPlugInsURL) throws -> [TunnelPlugin] {
        guard let directory else { throw SeverError.message("В установленном приложении нет папки VPN-расширений") }
        let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try paths.filter { $0.pathExtension == "appex" }.compactMap { path in
            let data = try Data(contentsOf: path.appendingPathComponent("Info.plist"))
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            return TunnelPlugin(info: info)
        }
    }

    static func identifier(for engine: TunnelEngine, in plugins: [TunnelPlugin]) throws -> String {
        let matches = plugins.filter { $0.engine == engine }
        guard matches.count == 1 else {
            let name = engine == .openvpn ? "OpenVPN" : "Xray"
            throw SeverError.message(matches.isEmpty
                ? "В установленном приложении не найдено VPN-расширение \(name). Проверьте, что инструмент подписи сохранил оба расширения"
                : "Найдено несколько расширений \(name); нельзя однозначно выбрать нужное")
        }
        return matches[0].identifier
    }
}

enum VPNFailure {
    static func text(_ error: Error) -> String {
        if let error = error as? SeverError { return error.localizedDescription }
        let value = error as NSError
        if value.domain == "dev.sever.tunnel" {
            // This domain is emitted only by our extension with fixed, secret-free messages.
            return value.localizedDescription + " (код \(value.code))"
        }
        if value.domain == "NEVPNErrorDomain" || value.domain == "NEVPNConnectionErrorDomain" {
            return "Ошибка iOS: \(value.domain), код \(value.code)"
        }
        return "Не удалось выполнить операцию VPN (код \(value.code))"
    }
}
