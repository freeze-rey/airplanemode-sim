import Foundation
import AirplaneModeCore

private func nslog(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    let path = "/tmp/airplanemode-app.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(Data(line.utf8))
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
}

/// Central state for the AirplaneMode menu bar app.
/// Thin SwiftUI adapter around AirplaneModeSession.
@Observable
@MainActor
final class AirplaneModeStore {
    // MARK: - State

    var isActive = false
    var selectedProfile: PresetProfile = .none
    var stats: MetricsSnapshot?
    var statsHistory: [MetricsSnapshot] = []
    var isRelayRunning = false
    var setupComplete: Bool
    var errorMessage: String?
    var isLoading = false

    enum Destination { case main, customProfile, domains }
    var destination: Destination = .main
    var matchDomains: [String] {
        didSet { UserDefaults.standard.set(matchDomains, forKey: "matchDomains") }
    }

    // MARK: - Custom profile fields

    var customName = "Custom"
    var customLatencyMs = ""
    var customJitterMeanMs = ""
    var customJitterP99Ms = ""
    var customPacketLoss = ""
    var customBurstLen = ""
    var customBandwidthKBs = ""

    // MARK: - Private

    private let session: AirplaneModeSession
    private var pollingTask: Task<Void, Never>?
    private var activatedAt: Date?
    private var consecutivePollFailures = 0
    private var didSync = false

    private static let maxHistoryCount = 60
    private static let maxPollFailures = 3

    // MARK: - Derived

    var activeProfileDisplayName: String {
        stats?.profileName ?? selectedProfile.displayName
    }

    var uptimeString: String {
        guard let start = activatedAt else { return "0s" }
        let elapsed = Int(Date().timeIntervalSince(start))
        if elapsed < 60 { return "\(elapsed)s" }
        let min = elapsed / 60
        let sec = elapsed % 60
        return "\(min)m \(sec)s"
    }

    var lossPercentage: String {
        guard let s = stats, s.packetsTotal > 0 else { return "0%" }
        let pct = Double(s.drops) / Double(s.packetsTotal) * 100
        return String(format: "%.2f%%", pct)
    }

    var latencyColor: LatencyStatus {
        guard let s = stats else { return .good }
        if s.latencyMs > 500 || s.drops > 0 { return .bad }
        if s.latencyMs > 200 { return .moderate }
        return .good
    }

    /// Only includes snapshots where traffic was actually flowing.
    private var activeHistory: [MetricsSnapshot] {
        statsHistory.filter { !$0.idle }
    }

    var latencyHistory: [Double] {
        activeHistory.map { Double($0.latencyMs) }
    }

    var throughputHistory: [Double] {
        activeHistory.map { Double($0.throughputBytesPerSec) }
    }

    var hasRecentActivity: Bool {
        activeHistory.count >= 3
    }

    // MARK: - Init

    init() {
        let binaryPath = AirplaneModeSession.defaultRelayBinaryPath()
        self.session = AirplaneModeSession(relayBinaryPath: binaryPath)
        setupComplete = SetupManager.isSetupComplete()
        matchDomains = UserDefaults.standard.stringArray(forKey: "matchDomains") ?? []
    }

    // MARK: - Daemon detection

    /// Called on app launch to detect a daemon already started by CLI or a previous session.
    func syncOnAppear() async {
        guard !didSync else { return }
        didSync = true
        let found = await session.syncWithDaemon()
        if found {
            isActive = true
            isRelayRunning = true
            if case .active(let profile, _) = session.state {
                selectedProfile = PresetProfile(rawValue: profile) ?? .none
            }
            if let daemonState = LaunchdManager.readState() {
                if !daemonState.domains.isEmpty {
                    matchDomains = daemonState.domains
                }
                activatedAt = daemonState.startedAt
            }
            startStatsPolling()
        }
    }

    private func clearStats() {
        stats = nil
        statsHistory = []
    }

    // MARK: - Activate / Deactivate

    func activate() async {
        guard !isActive else { return }
        isLoading = true
        errorMessage = nil
        nslog("activate: session binary path")

        do {
            if !setupComplete {
                nslog("setup not complete")
                errorMessage = "TLS certificates not found. Run: make setup"
                isLoading = false
                return
            }

            nslog("activating session...")
            try await session.activate(
                profile: selectedProfile.rawValue,
                domains: matchDomains
            )
            nslog("session activated")

            isActive = true
            isRelayRunning = true
            activatedAt = Date()
            clearStats()
            startStatsPolling()
        } catch {
            nslog("activate failed: \(error)")
            errorMessage = error.localizedDescription
            await deactivate()
        }

        isLoading = false
    }

    func deactivate() async {
        stopStatsPolling()
        await session.deactivate()

        isActive = false
        activatedAt = nil
        stats = nil
        statsHistory = []
        isRelayRunning = false
        errorMessage = nil
    }

    // MARK: - Profile switching

    func setProfile(_ preset: PresetProfile) async {
        selectedProfile = preset
        guard isActive else { return }

        do {
            try await session.switchProfile(preset.rawValue)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyCustomProfile() async {
        guard isActive else { return }

        let profile = NetworkProfile(
            name: customName,
            latencyMs: Int(customLatencyMs) ?? 0,
            jitterMeanMs: Int(customJitterMeanMs) ?? 0,
            jitterP99Ms: Int(customJitterP99Ms) ?? 0,
            packetLoss: (Double(customPacketLoss) ?? 0) / 100.0,
            burstLen: Int(customBurstLen) ?? 0,
            bandwidthBps: (Int(customBandwidthKBs) ?? 0) * 1000
        )

        do {
            let encoder = JSONEncoder()
            let json = try encoder.encode(profile)
            let jsonString = String(data: json, encoding: .utf8) ?? "{}"
            try await session.switchProfile(jsonString)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Updates the matched domains and reinstalls the profile.
    func updateDomains(_ domains: [String]) async {
        matchDomains = domains
        guard isActive else { return }

        clearStats()

        // Reinstall profile with new domains
        ProfileGenerator.removeProfile()
        do {
            let hostname = ProfileGenerator.localHostname()
            try ProfileGenerator.installProfile(hostname: hostname, port: 4433, matchDomains: matchDomains)
        } catch {
            errorMessage = error.localizedDescription
        }

        // Update daemon state file so CLI sees the new domains
        if let existingState = LaunchdManager.readState() {
            let updatedState = DaemonState(
                profile: existingState.profile,
                domains: domains,
                startedAt: existingState.startedAt
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(updatedState).write(to: LaunchdManager.stateFileURL)
        }
    }

    // MARK: - Stats polling

    private func startStatsPolling() {
        pollingTask?.cancel()
        consecutivePollFailures = 0
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                    guard let self else { return }
                    let snapshot = try await self.session.pollStats()
                    self.consecutivePollFailures = 0
                    self.stats = snapshot
                    self.statsHistory.append(snapshot)
                    if self.statsHistory.count > Self.maxHistoryCount {
                        self.statsHistory.removeFirst(
                            self.statsHistory.count - Self.maxHistoryCount)
                    }
                } catch {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    self.consecutivePollFailures += 1
                    if self.consecutivePollFailures >= Self.maxPollFailures {
                        self.errorMessage = "Lost connection to relay"
                        await self.deactivate()
                        return
                    }
                }
            }
        }
    }

    private func stopStatsPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}

enum LatencyStatus: Sendable {
    case good
    case moderate
    case bad

    var color: String {
        switch self {
        case .good: "green"
        case .moderate: "yellow"
        case .bad: "red"
        }
    }
}
