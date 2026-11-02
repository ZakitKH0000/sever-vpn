import Foundation

struct AISettings: Codable {
    var endpoint = ""
    var model = ""
    var key = ""
    static func load() throws -> AISettings {
        guard let data = try SecretStore.read(account: "ai-settings") else { return AISettings() }
        return try JSONDecoder().decode(AISettings.self, from: data)
    }
    func save() throws { try SecretStore.write(JSONEncoder().encode(self), account: "ai-settings") }
    var isReady: Bool { !key.isEmpty && !model.isEmpty && URL(string: endpoint)?.scheme == "https" }
}

enum AIClient {
    // The caller passes only ConfigurationCore.safeDiagnostic output. No configuration or raw logs enter this API.
    static func explain(safeReport: String, settings: AISettings) async throws -> String {
        guard settings.isReady, let url = URL(string: settings.endpoint) else {
            throw SeverError.message("Добавьте адрес API, модель и ключ ИИ в настройках")
        }
        let payload: [String: Any] = ["model": settings.model, "max_tokens": 700,
            "messages": [["role": "system", "content": "Ты помощник VPN-приложения Север. Отвечай по-русски коротко и понятно. По обезличенным результатам проверок объясни, что проверено, а что неизвестно. Не обещай обход блокировок. Не предлагай отключать проверку сертификатов или блокировку прямого трафика. Не выдумывай логи. Предложения не применяются автоматически."],
                         ["role": "user", "content": safeReport]]]
        let data = try await HTTPClient.fetch(url, method: "POST", body: JSONSerialization.data(withJSONObject: payload), bearer: settings.key, maximumBytes: 256 * 1024)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty else {
            throw SeverError.message("ИИ-сервис вернул неизвестный формат ответа")
        }
        return String(text.prefix(8000))
    }
}
