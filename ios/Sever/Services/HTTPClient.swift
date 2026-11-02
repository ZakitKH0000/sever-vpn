import Foundation

private final class SameHostHTTPSRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = request.url?.scheme == "https" && request.url?.host == task.originalRequest?.url?.host
        completionHandler(allowed ? request : nil)
    }
}

enum HTTPClient {
    static func fetch(_ url: URL, method: String = "GET", body: Data? = nil,
                      bearer: String? = nil, maximumBytes: Int = 4 * 1024 * 1024) async throws -> Data {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw SeverError.message("Нужна HTTPS-ссылка без логина и пароля в адресе")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        let delegate = SameHostHTTPSRedirects()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Sever/0.1", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SeverError.message("Источник не вернул данные. Проверьте доступность и срок действия ссылки")
        }
        if response.expectedContentLength > maximumBytes { throw SeverError.message("Ответ источника слишком большой") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw SeverError.message("Ответ источника слишком большой") }
            data.append(byte)
        }
        return data
    }
}
