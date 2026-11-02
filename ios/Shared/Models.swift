import Foundation

enum TunnelEngine: String, Codable { case xray, openvpn }

struct ProfileSeed: Decodable {
    let name: String
    let engine: TunnelEngine
    let configuration: String
    let host: String
    let port: Int
    let country: String
    let source: String
    let nodes: Int
}

struct ServerProfile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    let engine: TunnelEngine
    let configuration: String
    let host: String
    let port: Int
    let country: String
    let source: String
    let nodes: Int
    var latency: Int?

    var engineLabel: String { engine == .xray ? "Xray" : "OpenVPN" }
}

struct SubscriptionSource: Codable, Identifiable {
    let id: String
    let url: URL
    var updatedAt: Date
}

struct SavedState: Codable {
    var profiles: [ServerProfile] = []
    var subscriptions: [SubscriptionSource] = []
    var feedUpdatedAt: Date?
}

struct TunnelCandidate: Codable {
    let configuration: String
    let username: String?
    let password: String?
}

struct TunnelEnvelope: Codable {
    let version: Int
    let engine: TunnelEngine
    let candidates: [TunnelCandidate]
}

struct DiagnosticCheck: Codable, Identifiable {
    var id: String { target }
    let target: String
    let ok: Bool
    let milliseconds: Int
    let error: String?
    var title: String {
        switch target { case "cloudflare": return "Cloudflare"; case "google": return "Google"; default: return "Apple" }
    }
}

struct DiagnosticReport: Codable {
    let tunnel: String
    let engine: String?
    let checks: [DiagnosticCheck]
}

enum SeverError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
