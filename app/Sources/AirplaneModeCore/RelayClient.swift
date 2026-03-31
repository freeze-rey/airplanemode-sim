import Foundation

/// HTTP client for the Go relay's control API (localhost:4434).
public struct RelayClient: Sendable {
    public let controlURL: URL

    public init(controlURL: URL = URL(string: "http://localhost:4434")!) {
        self.controlURL = controlURL
    }

    /// POST /profile — switches the relay's active network profile.
    public func setProfile(_ id: String) async throws {
        var request = URLRequest(url: controlURL.appendingPathComponent("profile"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["id": id]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw RelayError.profileSetFailed(body)
        }
    }

    /// GET /stats — returns the current MetricsSnapshot.
    public func getStats() async throws -> MetricsSnapshot {
        let url = controlURL.appendingPathComponent("stats")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RelayError.statsFailed
        }
        return try JSONDecoder().decode(MetricsSnapshot.self, from: data)
    }

    /// GET /health — returns true if the relay is healthy.
    public func checkHealth() async throws -> Bool {
        let url = controlURL.appendingPathComponent("health")
        let (_, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }
}

public enum RelayError: Error, LocalizedError, Sendable {
    case profileSetFailed(String)
    case statsFailed
    case relayNotRunning
    case setupRequired

    public var errorDescription: String? {
        switch self {
        case .profileSetFailed(let msg): "Failed to set profile: \(msg)"
        case .statsFailed: "Failed to fetch stats"
        case .relayNotRunning: "Relay process is not running"
        case .setupRequired: "TLS setup required. Run 'airplanemode setup' first."
        }
    }
}
