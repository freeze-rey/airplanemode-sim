import Foundation
import AirplaneModeCore

struct CLI {
    static func run(_ args: [String]) async {
        guard let command = args.first else {
            printUsage()
            return
        }

        do {
            switch command {
            case "start":
                try await cmdStart(args: Array(args.dropFirst()))
            case "stop":
                let subArgs = Array(args.dropFirst())
                try cmdStop(uninstall: subArgs.contains("--uninstall"))
            case "status":
                let subArgs = Array(args.dropFirst())
                let follow = subArgs.contains("--follow") || subArgs.contains("-f")
                try await cmdStatus(follow: follow)
            case "set":
                guard args.count >= 2 else {
                    printErr("Usage: airplanemode set <profile-id>")
                    exit(1)
                }
                try await cmdSet(profileID: args[1])
            case "profiles":
                cmdProfiles()
            case "help", "--help", "-h":
                printUsage()
            default:
                printErr("Unknown command: \(command)")
                printUsage()
                exit(1)
            }
        } catch {
            printErr("Error: \(error.localizedDescription)")
            exit(1)
        }
    }

    // MARK: - Commands

    static func cmdStart(args: [String]) async throws {
        let profile = parseFlag(args, flag: "--profile") ?? "none"
        let domainsStr = parseFlag(args, flag: "--domains")
        let systemWide = args.contains("--all") || domainsStr == "*"
        var domains = domainsStr?.split(separator: ",").map(String.init).filter { $0 != "*" } ?? []

        // If no domains specified, try to reuse previously configured domains
        if domains.isEmpty, !systemWide {
            let saved = UserDefaults.standard.stringArray(forKey: "matchDomains") ?? []
            if !saved.isEmpty {
                domains = saved
                print("Resuming with previously configured domains: \(domains.joined(separator: ", "))")
            } else {
                printErr("Specify domains to profile with --domains, or use --all for system-wide.")
                printErr("")
                printErr("  airplanemode start --profile turkish-air --domains facebook.com,example.com")
                printErr("  airplanemode start --profile turkish-air --all")
                exit(1)
            }
        }

        let manager = LaunchdManager()

        // Check for existing daemon
        let status = await manager.checkDaemon()
        switch status {
        case .running(let pid, let state):
            print("Relay already running (PID \(pid))")
            if let state {
                print("  Condition: \(state.profile)")
                if !state.domains.isEmpty {
                    print("  Domains:   \(state.domains.joined(separator: ", "))")
                } else {
                    print("  Scope:     system-wide")
                }
            }
            launchGUI()
            return
        case .starting:
            print("Relay is starting...")
            launchGUI()
            return
        case .notRunning:
            break
        }

        // Validate TLS setup
        guard SetupManager.isSetupComplete() else {
            printErr("TLS certificates not found. Run: make setup  (in the AirplaneMode directory)")
            exit(1)
        }

        // Find relay binary: PATH first, then relative to source
        guard let binaryPath = resolveRelayBinary() else {
            printErr("airplanemode-relay not found.")
            printErr("Install it with: make install  (in the AirplaneMode directory)")
            exit(1)
        }

        // Bootstrap LaunchAgent
        print("Starting relay daemon...")
        try manager.startDaemon(
            relayBinaryPath: binaryPath,
            profile: profile,
            domains: domains
        )
        print("  Log: \(LaunchdManager.logFileURL.path)")

        // Wait for health
        print("Waiting for relay to become healthy...")
        let client = RelayClient()
        var healthy = false
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            if let ok = try? await client.checkHealth(), ok {
                healthy = true
                break
            }
        }
        guard healthy else {
            printErr("Relay failed to start. Check logs: \(LaunchdManager.logFileURL.path)")
            manager.stopDaemon()
            exit(1)
        }

        // Set profile if not "none"
        if profile != "none" {
            try await client.setProfile(profile)
        }

        // Install mobileconfig (skips if domains unchanged)
        let hostname = ProfileGenerator.localHostname()
        let reason = try ProfileGenerator.installProfile(hostname: hostname, port: 4433, matchDomains: domains)

        if let pid = LaunchdManager.queryLaunchdPID() {
            print("✓ Relay running (PID \(pid))")
        } else {
            print("✓ Relay running")
        }

        if let reason {
            // Profile was (re)installed — need approval
            print("  Profile install: \(reason)")
            print("")
            print("Approve the profile in System Settings to start routing traffic.")
            print("Waiting for profile approval...")

            // Probe a matched domain to verify routing without waiting for user traffic
            let probeResult = await probeRouting(client: client, domains: domains, timeoutSeconds: 30)
            if probeResult {
                print("✓ Profile approved — traffic is being conditioned")
            } else {
                print("")
                print("⚠ No traffic detected after 30s.")
                print("  1. Open System Settings → General → Profiles & Device Management")
                print("  2. Click \"AirplaneMode Relay\" → Install")
                print("  3. If it fails, ensure mkcert CA is set to \"Always Trust\" in Keychain Access")
            }
        } else {
            print("✓ Profile already installed (domains unchanged)")
        }

        print("")
        print("  Condition: \(profile)")
        if !domains.isEmpty {
            print("  Domains:   \(domains.joined(separator: ", "))")
        } else {
            print("  Scope:     system-wide")
        }
        print("")
        print("  airplanemode status    — check status")
        print("  airplanemode status -f — follow live stats")
        print("  airplanemode stop      — stop and clean up")

        launchGUI()
    }

    /// Probes routing by making a request to a matched domain and checking if
    /// the relay sees packets. This verifies the profile is installed without
    /// waiting for the user to generate traffic.
    static func probeRouting(client: RelayClient, domains: [String], timeoutSeconds: Int) async -> Bool {
        for i in 0..<timeoutSeconds {
            // Check if relay already has traffic
            if let stats = try? await client.getStats(), stats.packetsTotal > 0 { return true }

            // Actively probe a matched domain every 3 seconds
            if i % 3 == 0, let domain = domains.first {
                Task.detached {
                    let url = URL(string: "https://\(domain)/")!
                    _ = try? await URLSession.shared.data(from: url)
                }
            }

            if i > 0, i % 10 == 0 {
                print("  Still waiting... (\(i)s)")
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    static func cmdStop(uninstall: Bool = false) throws {
        let manager = LaunchdManager()

        if uninstall {
            ProfileGenerator.removeProfile()
            print("✓ Profile removed")
        } else {
            print("  Profile kept (macOS falls back to direct when relay is down)")
            print("  Use 'airplanemode stop --uninstall' to remove the profile")
        }

        if manager.stopDaemon() {
            print("✓ Relay stopped")
        } else {
            print("  No relay daemon found")
        }
    }

    static func cmdStatus(follow: Bool = false) async throws {
        if follow {
            try await cmdStatusFollow()
            return
        }

        let manager = LaunchdManager()
        let status = await manager.checkDaemon()

        switch status {
        case .notRunning:
            print("Relay: not running")
            if ProfileGenerator.isProfileActive {
                print("")
                print("⚠ System profile is still installed — traffic is being routed to a dead relay!")
                print("  Run: airplanemode stop")
            }

        case .starting:
            print("Relay: starting")
            print("  Health check not yet passing. Check logs:")
            print("  \(LaunchdManager.logFileURL.path)")

        case .running(let pid, let state):
            let stats = try await RelayClient().getStats()
            let routing = stats.packetsTotal > 0
            print("Relay:      running (PID \(pid))")
            print("Condition:  \(stats.profileName)")
            print("Routing:    \(routing ? "active (\(stats.packetsTotal) packets)" : "waiting for traffic")")
            print("Latency:    \(stats.latencyMs)ms  Jitter: \(stats.jitterMs)ms")
            print("Throughput: \(formatBytes(stats.throughputBytesPerSec))/s")
            if stats.drops > 0 {
                print("Drops:      \(stats.drops)")
            }
            if let state {
                if !state.domains.isEmpty {
                    print("Domains:    \(state.domains.joined(separator: ", "))")
                } else {
                    print("Scope:      system-wide")
                }
                let elapsed = Int(Date().timeIntervalSince(state.startedAt))
                print("Uptime:     \(formatUptime(elapsed))")
            }
            print("Log:        \(LaunchdManager.logFileURL.path)")
        }
    }

    static func cmdStatusFollow() async throws {
        print("Following relay status (Ctrl+C to stop)...\n")

        let shouldStop = ManagedAtomic(false)

        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { shouldStop.store(true); src.cancel() }
        src.resume()
        signal(SIGINT, SIG_IGN)

        let client = RelayClient()
        var firstLine = true
        while !shouldStop.load() {
            if !firstLine {
                // Move cursor up one line and clear it
                print("\u{1B}[1A\u{1B}[2K", terminator: "")
            }
            firstLine = false

            if let stats = try? await client.getStats() {
                let routing = stats.packetsTotal > 0
                print("[\(stats.profileName)] \(stats.latencyMs)ms | \(formatBytes(stats.throughputBytesPerSec))/s | \(stats.packetsTotal) pkts\(stats.drops > 0 ? " | \(stats.drops) drops" : "") | \(routing ? "routing" : "waiting")")
            } else {
                print("Relay not responding")
            }
            fflush(stdout)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    static func cmdSet(profileID: String) async throws {
        let client = RelayClient()
        try await client.setProfile(profileID)
        let stats = try await client.getStats()
        print("✓ Profile: \(stats.profileName)")
    }

    static func cmdProfiles() {
        print("ID            Name             Latency   Bandwidth    Loss")
        print(String(repeating: "-", count: 60))
        for preset in PresetProfile.allCases {
            let id = preset.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
            let name = preset.displayName.padding(toLength: 16, withPad: " ", startingAt: 0)
            let latency = (preset.latencyLabel.isEmpty ? "-" : preset.latencyLabel)
                .padding(toLength: 9, withPad: " ", startingAt: 0)
            let bw = bandwidthLabel(preset).padding(toLength: 12, withPad: " ", startingAt: 0)
            let loss = lossLabel(preset)
            print("\(id) \(name) \(latency) \(bw) \(loss)")
        }
    }

    // MARK: - GUI launch

    /// Launches the menu bar app as a detached process.
    static func launchGUI() {
        // Resolve the actual binary path — CommandLine.arguments[0] may be
        // a bare name like "airplanemode" when invoked via PATH.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["airplanemode"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let resolved = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !resolved.isEmpty else { return }

            let gui = Process()
            gui.executableURL = URL(fileURLWithPath: resolved)
            gui.arguments = ["--gui"]
            gui.standardOutput = FileHandle.nullDevice
            gui.standardError = FileHandle.nullDevice
            try gui.run()
        } catch {}
    }

    // MARK: - Helpers

    static func printUsage() {
        print("""
        AirplaneMode — macOS network profiler

        Usage:
          airplanemode start --profile <id> --domains <d1,d2,...>   Start with domain scoping
          airplanemode start --profile <id> --all                  Start system-wide
          airplanemode stop                                        Stop and remove profile
          airplanemode status                                      Show status and stats
          airplanemode status --follow                             Continuously monitor stats
          airplanemode set <profile-id>                            Switch profile on the fly
          airplanemode profiles                                    List available presets

        Examples:
          airplanemode start --profile turkish-air --domains facebook.com,instagram.com
          airplanemode start --profile turkish-air --all
          airplanemode set starlink
          airplanemode status -f
          airplanemode stop
        """)
    }

    /// Finds airplanemode-relay: checks well-known install paths, PATH, then dev relative path.
    static func resolveRelayBinary() -> String? {
        let fm = FileManager.default

        // Check common install locations directly (shells may not have ~/.local/bin in PATH)
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/airplanemode-relay",
            "/usr/local/bin/airplanemode-relay",
        ]
        for path in candidates {
            if fm.fileExists(atPath: path) { return path }
        }

        // Check PATH via `which`
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["airplanemode-relay"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty { return path }
            }
        } catch {}

        // Fall back to relative path (development)
        let devPath = AirplaneModeSession.defaultRelayBinaryPath()
        if fm.fileExists(atPath: devPath) { return devPath }

        return nil
    }

    static func printErr(_ msg: String) {
        FileHandle.standardError.write(Data("\(msg)\n".utf8))
    }

    static func parseFlag(_ args: [String], flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    static func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.0f KB", Double(bytes) / 1_000) }
        return "\(bytes) B"
    }

    static func formatUptime(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let min = seconds / 60
        let sec = seconds % 60
        if min < 60 { return "\(min)m \(sec)s" }
        let hrs = min / 60
        return "\(hrs)h \(min % 60)m"
    }

    static func bandwidthLabel(_ preset: PresetProfile) -> String {
        switch preset {
        case .none: "-"
        case .starlink: "500 KB/s"
        case .jetblue: "3.3 Mbps"
        case .american: "4.2 Mbps"
        case .turkishAir: "86 KB/s"
        }
    }

    static func lossLabel(_ preset: PresetProfile) -> String {
        switch preset {
        case .none: "-"
        case .starlink: "1.0%"
        case .jetblue: "0.5%"
        case .american: "0.5%"
        case .turkishAir: "0.5%"
        }
    }
}

/// Simple atomic boolean for signal handling.
private final class ManagedAtomic: @unchecked Sendable {
    private var _value: Bool
    private let lock = NSLock()

    init(_ value: Bool) { _value = value }

    func load() -> Bool { lock.withLock { _value } }
    func store(_ value: Bool) { lock.withLock { _value = value } }
}
