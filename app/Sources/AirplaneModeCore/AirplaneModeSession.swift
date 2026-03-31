import Foundation

/// Manages the full AirplaneMode lifecycle: relay process, mobileconfig, control API.
/// Delegates to LaunchdManager for daemon management (same code path as CLI).
/// Usable from both CLI and SwiftUI — no UI dependencies.
public final class AirplaneModeSession: @unchecked Sendable {
    public enum State: Sendable {
        case idle
        case starting
        case active(profile: String, pid: Int32)
        case stopping
        case failed(String)
    }

    private let relayBinaryPath: String
    private let relayClient: RelayClient
    private let launchdManager: LaunchdManager

    public private(set) var state: State = .idle

    /// Creates a session with the given relay binary path.
    /// - Parameter relayBinaryPath: Path to the `airplanemode-relay` Go binary.
    public init(relayBinaryPath: String) {
        self.relayBinaryPath = relayBinaryPath
        self.relayClient = RelayClient()
        self.launchdManager = LaunchdManager(relayClient: relayClient)
    }

    // MARK: - Lifecycle

    /// Full activation: start LaunchAgent → health check → install profile → set profile.
    public func activate(profile: String = "none", domains: [String] = []) async throws {
        guard case .idle = state else { return }
        state = .starting

        guard SetupManager.isSetupComplete() else {
            state = .failed("TLS setup required")
            throw RelayError.setupRequired
        }

        do {
            try launchdManager.startDaemon(
                relayBinaryPath: relayBinaryPath,
                profile: profile,
                domains: domains
            )
            try await waitForHealth()
            try installProfile(domains: domains)
            if profile != "none" {
                try await relayClient.setProfile(profile)
            }
            let pid = LaunchdManager.queryLaunchdPID() ?? 0
            state = .active(profile: profile, pid: pid)
        } catch {
            state = .failed(error.localizedDescription)
            await deactivate()
            throw error
        }
    }

    /// Stop the relay. Profile is kept installed (macOS falls back to direct).
    public func deactivate() async {
        state = .stopping
        launchdManager.stopDaemon()
        state = .idle
    }

    /// Checks if a daemon is already running (e.g., started by CLI) and syncs state.
    /// Returns true if an active daemon was found.
    @discardableResult
    public func syncWithDaemon() async -> Bool {
        let status = await launchdManager.checkDaemon()
        switch status {
        case .running(let pid, let daemonState):
            let profile = daemonState?.profile ?? "none"
            state = .active(profile: profile, pid: pid)
            return true
        case .starting:
            state = .starting
            return true
        case .notRunning:
            state = .idle
            return false
        }
    }

    /// Switch profile on a running relay.
    public func switchProfile(_ id: String) async throws {
        try await relayClient.setProfile(id)
        if case .active(_, let pid) = state {
            state = .active(profile: id, pid: pid)
        }
    }

    /// Poll stats from the running relay.
    public func pollStats() async throws -> MetricsSnapshot {
        try await relayClient.getStats()
    }

    /// Check if the relay is healthy.
    public func checkHealth() async -> Bool {
        (try? await relayClient.checkHealth()) ?? false
    }

    // MARK: - Private helpers

    private func waitForHealth() async throws {
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            if let healthy = try? await relayClient.checkHealth(), healthy {
                return
            }
        }
        throw RelayError.relayNotRunning
    }

    private func installProfile(domains: [String]) throws {
        let hostname = ProfileGenerator.localHostname()
        try ProfileGenerator.installProfile(hostname: hostname, port: 4433, matchDomains: domains)
    }

    /// Resolve relay binary path relative to this source file (for development).
    public static func defaultRelayBinaryPath() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AirplaneModeCore/
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // app/
            .deletingLastPathComponent() // AirplaneMode/
            .appendingPathComponent("relay/airplanemode-relay")
            .standardized
            .path
    }
}
