import Foundation
import Network

enum ConnectionChecks {
    static func tcp(host: String, port: Int) async -> Int? {
        guard (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "dev.sever.tcp-probe")
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let started = Date()
            var finished = false
            var timeout: DispatchWorkItem?
            func finish(_ result: Int?) {
                guard !finished else { return }; finished = true
                timeout?.cancel(); connection.stateUpdateHandler = nil; connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state { case .ready: finish(Int(Date().timeIntervalSince(started) * 1000)); case .failed, .cancelled: finish(nil); default: break }
            }
            let deadline = DispatchWorkItem { finish(nil) }
            timeout = deadline
            queue.asyncAfter(deadline: .now() + 3, execute: deadline)
            connection.start(queue: queue)
        }
    }

    static func internet() async -> [DiagnosticCheck] {
        let targets = [("cloudflare", "https://cp.cloudflare.com/generate_204"),
                       ("google", "https://www.gstatic.com/generate_204"),
                       ("apple", "https://www.apple.com/library/test/success.html")]
        return await withTaskGroup(of: DiagnosticCheck.self) { group in
            for (name, address) in targets {
                group.addTask {
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 8
                    configuration.timeoutIntervalForResource = 10
                    let session = URLSession(configuration: configuration)
                    defer { session.invalidateAndCancel() }
                    let started = Date()
                    do {
                        var request = URLRequest(url: URL(string: address)!)
                        request.httpMethod = "HEAD"; request.cachePolicy = .reloadIgnoringLocalCacheData
                        let (_, response) = try await session.data(for: request)
                        let ok = (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
                        return DiagnosticCheck(target: name, ok: ok, milliseconds: Int(Date().timeIntervalSince(started) * 1000), error: ok ? nil : "http")
                    } catch {
                        let code = (error as NSError).code
                        return DiagnosticCheck(target: name, ok: false, milliseconds: Int(Date().timeIntervalSince(started) * 1000), error: code == NSURLErrorTimedOut ? "timeout" : "network")
                    }
                }
            }
            var checks: [DiagnosticCheck] = []
            for await check in group { checks.append(check) }
            return checks.sorted { $0.target < $1.target }
        }
    }
}
