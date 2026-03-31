import Foundation

/// Launch-time config persisted alongside the LaunchAgent.
/// launchd doesn't track profile/domains, so we store them separately.
public struct DaemonState: Codable, Sendable {
    public let profile: String
    public let domains: [String]
    public let startedAt: Date

    public init(profile: String, domains: [String], startedAt: Date) {
        self.profile = profile
        self.domains = domains
        self.startedAt = startedAt
    }
}

/// Status of the AirplaneMode relay daemon.
public enum DaemonStatus: Sendable {
    case notRunning
    case starting
    case running(pid: Int32, state: DaemonState?)
}

/// Manages the AirplaneMode relay as a macOS LaunchAgent via launchctl.
public struct LaunchdManager: Sendable {
    public static let serviceLabel = "com.airplanemode.relay"

    public static let plistURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(serviceLabel).plist")
    }()

    public static let stateFileURL = SetupManager.supportDir.appendingPathComponent("daemon.json")
    public static let logFileURL = SetupManager.supportDir.appendingPathComponent("relay.log")

    private let relayClient: RelayClient

    public init(relayClient: RelayClient = RelayClient()) {
        self.relayClient = relayClient
    }

    // MARK: - Status

    /// Full liveness check: plist exists → launchctl print → health endpoint.
    public func checkDaemon() async -> DaemonStatus {
        guard FileManager.default.fileExists(atPath: Self.plistURL.path) else {
            return .notRunning
        }

        let pid = Self.queryLaunchdPID()

        let healthy = (try? await relayClient.checkHealth()) ?? false
        if healthy {
            let state = Self.readState()
            return .running(pid: pid ?? 0, state: state)
        }

        if pid != nil {
            return .starting
        }
        return .notRunning
    }

    /// Reads the persisted daemon state, or nil if not present.
    public static func readState() -> DaemonState? {
        guard let data = try? Data(contentsOf: stateFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DaemonState.self, from: data)
    }

    // MARK: - Start

    /// Generates a LaunchAgent plist and bootstraps it via launchctl.
    public func startDaemon(
        relayBinaryPath: String,
        profile: String,
        domains: [String]
    ) throws {
        let fm = FileManager.default
        let certs = SetupManager.certPaths()
        let hostname = ProfileGenerator.localHostname()

        // Ensure directories exist
        let launchAgentsDir = Self.plistURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: launchAgentsDir.path) {
            try fm.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: SetupManager.supportDir.path) {
            try fm.createDirectory(at: SetupManager.supportDir, withIntermediateDirectories: true)
        }

        // Truncate log file
        fm.createFile(atPath: Self.logFileURL.path, contents: nil)

        // Generate and write plist
        let plistData = Self.generatePlist(
            label: Self.serviceLabel,
            program: relayBinaryPath,
            environment: [
                "CERT_FILE": certs.cert,
                "KEY_FILE": certs.key,
                "RELAY_HOST": hostname,
            ],
            logPath: Self.logFileURL.path
        )
        try plistData.write(to: Self.plistURL)

        // Bootstrap via launchctl
        let uid = Self.currentUID()
        try Self.runLaunchctl(["bootstrap", "gui/\(uid)", Self.plistURL.path])

        // Write state file
        let state = DaemonState(
            profile: profile,
            domains: domains,
            startedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(state).write(to: Self.stateFileURL)
    }

    // MARK: - Stop

    /// Boots out the LaunchAgent and cleans up files.
    /// Returns true if the service was found and stopped.
    @discardableResult
    public func stopDaemon() -> Bool {
        let uid = Self.currentUID()
        let stopped = Self.tryRunLaunchctl(["bootout", "gui/\(uid)/\(Self.serviceLabel)"])
        Self.cleanup()
        return stopped
    }

    /// Removes plist and state files.
    public static func cleanup() {
        let fm = FileManager.default
        try? fm.removeItem(at: plistURL)
        try? fm.removeItem(at: stateFileURL)
    }

    // MARK: - Plist generation

    /// Generates a LaunchAgent plist as XML data.
    public static func generatePlist(
        label: String,
        program: String,
        environment: [String: String],
        logPath: String
    ) -> Data {
        let envEntries = environment
            .sorted(by: { $0.key < $1.key })
            .map { key, value in
                """
                        <key>\(key)</key>
                        <string>\(value)</string>
                """
            }
            .joined(separator: "\n")

        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
                <key>Program</key>
                <string>\(program)</string>
                <key>EnvironmentVariables</key>
                <dict>
            \(envEntries)
                </dict>
                <key>StandardOutPath</key>
                <string>\(logPath)</string>
                <key>StandardErrorPath</key>
                <string>\(logPath)</string>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
        return Data(xml.utf8)
    }

    // MARK: - launchctl helpers

    /// Runs launchctl with the given arguments. Throws on non-zero exit.
    private static func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw LaunchdError.launchctlFailed(arguments.first ?? "", errMsg)
        }
    }

    /// Runs launchctl, returns true if exit code is 0.
    @discardableResult
    private static func tryRunLaunchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Queries launchctl print for the service PID.
    public static func queryLaunchdPID() -> Int32? {
        let uid = currentUID()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(uid)/\(serviceLabel)"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return parsePID(from: output)
        } catch {
            return nil
        }
    }

    /// Parses `pid = <number>` from launchctl print output.
    public static func parsePID(from output: String) -> Int32? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid = ") {
                let value = trimmed.dropFirst("pid = ".count)
                return Int32(value)
            }
        }
        return nil
    }

    /// Returns the current user's UID as a string.
    public static func currentUID() -> String {
        "\(getuid())"
    }
}

public enum LaunchdError: Error, LocalizedError, Sendable {
    case launchctlFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .launchctlFailed(let cmd, let msg):
            "launchctl \(cmd) failed: \(msg)"
        }
    }
}
