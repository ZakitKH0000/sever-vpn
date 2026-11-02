import Foundation

struct CatalogResult {
    let profiles: [ProfileSeed]
    let fetchedAt: Date
    let sourceName: String
}

struct BundledCatalog: Decodable {
    let fetchedAt: TimeInterval
    let profiles: [ProfileSeed]

    static func load() throws -> BundledCatalog? {
        guard let url = Bundle.main.url(forResource: "bootstrap-catalog", withExtension: "json") else { return nil }
        return try JSONDecoder().decode(BundledCatalog.self, from: Data(contentsOf: url))
    }
}

@MainActor
protocol CatalogLoading {
    func load(progress: (String) -> Void) async throws -> CatalogResult
}

@MainActor
final class CatalogService: CatalogLoading {
    static let sources: [(String, URL)] = [
        ("Основной каталог", URL(string: "https://www.vpngate.net/api/iphone/")!),
        ("Резервный каталог", URL(string: "https://download.vpngate.jp/api/iphone/")!)
    ]
    private let core: ConfigurationCore
    private let fetch: (URL) async throws -> Data

    init(core: ConfigurationCore, fetch: @escaping (URL) async throws -> Data = {
        try await HTTPClient.fetch($0, requestTimeout: 8, resourceTimeout: 12)
    }) {
        self.core = core
        self.fetch = fetch
    }

    func load(progress: (String) -> Void) async throws -> CatalogResult {
        var failures: [String] = []
        for (name, url) in Self.sources {
            if Task.isCancelled { throw CancellationError() }
            progress(name + ": загружаем список…")
            do {
                let data = try await fetch(url)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw SeverError.message("Ответ получен, но его кодировка не поддержана")
                }
                progress(name + ": проверяем полученный список…")
                let profiles: [ProfileSeed] = try core.call("vpnGate", input: text)
                guard !profiles.isEmpty else { throw SeverError.message("В ответе нет совместимых серверов") }
                return CatalogResult(profiles: profiles, fetchedAt: Date(), sourceName: name)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                failures.append(name + ": " + UserFacingErrors.text(error))
            }
        }
        throw SeverError.message(failures.joined(separator: "\n"))
    }
}

enum UserFacingErrors {
    static func text(_ error: Error) -> String {
        if let known = error as? SeverError { return known.localizedDescription }
        if error is DecodingError { return "Ответ получен, но формат списка не поддержан" }
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            let reason: String
            switch value.code {
            case NSURLErrorTimedOut: reason = "сайт не ответил вовремя"
            case NSURLErrorNotConnectedToInternet: reason = "нет подключения к интернету"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: reason = "не удалось найти адрес сайта"
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost: reason = "соединение с сайтом недоступно или прервано"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid: reason = "не удалось проверить защищённое соединение с сайтом"
            case NSURLErrorCancelled: reason = "загрузка отменена"
            default: reason = "ошибка подключения"
            }
            return "\(reason) (код \(value.code))"
        }
        // Never echo NSError descriptions: they may contain a private subscription URL.
        return "Операция не выполнена (код \(value.code))"
    }
}
