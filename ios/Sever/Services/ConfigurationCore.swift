import Foundation
import JavaScriptCore

private struct CoreResponse<Value: Decodable>: Decodable {
    let ok: Bool
    let value: Value?
    let error: String?
}

@MainActor
final class ConfigurationCore {
    private let context: JSContext

    init() throws {
        guard let context = JSContext(),
              let url = Bundle.main.url(forResource: "sever-core", withExtension: "js") else {
            throw SeverError.message("Не найден модуль обработки конфигураций")
        }
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        guard context.exception == nil else { throw SeverError.message("Не удалось загрузить обработчик конфигураций") }
        self.context = context
    }

    func call<T: Decodable>(_ method: String, input: Any, as type: T.Type = T.self) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed])
        guard let inputJSON = String(data: data, encoding: .utf8),
              let function = context.objectForKeyedSubscript("severCall"),
              let response = function.call(withArguments: [method, inputJSON])?.toString(),
              let encoded = response.data(using: .utf8) else {
            throw SeverError.message("Не удалось обработать конфигурацию")
        }
        let result = try JSONDecoder().decode(CoreResponse<T>.self, from: encoded)
        guard result.ok, let value = result.value else { throw SeverError.message(result.error ?? "Ошибка обработки") }
        return value
    }
}
