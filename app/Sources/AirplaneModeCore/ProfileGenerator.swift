import Foundation

/// Generates macOS .mobileconfig XML plist for relay routing.
public struct ProfileGenerator {
    private static func sanitizeHostname(_ hostname: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let sanitized = hostname.unicodeScalars.filter { allowed.contains($0) }
        let result = String(String.UnicodeScalarView(sanitized))
        return result.isEmpty ? "localhost" : result
    }

    public static func generate(hostname: String, port: Int, matchDomains: [String] = []) -> Data {
        let safeHostname = sanitizeHostname(hostname)
        let relayURL = "https://\(safeHostname).local:\(port)/"
        let uuid = UUID().uuidString
        let payloadUUID = UUID().uuidString
        let domainsXML = matchDomains.map { "                <string>\($0)</string>" }.joined(separator: "\n")

        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>PayloadContent</key>
                <array>
                    <dict>
                        <key>PayloadType</key>
                        <string>com.apple.relay.managed</string>
                        <key>PayloadIdentifier</key>
                        <string>com.airplanemode.relay.config</string>
                        <key>PayloadUUID</key>
                        <string>\(payloadUUID)</string>
                        <key>PayloadDisplayName</key>
                        <string>AirplaneMode Relay</string>
                        <key>PayloadVersion</key>
                        <integer>1</integer>
                        <key>Relays</key>
                        <array>
                            <dict>
                                <key>HTTP3RelayURL</key>
                                <string>\(relayURL)</string>
                            </dict>
                        </array>
                        <key>MatchDomains</key>
                        <array>
            \(domainsXML)
                        </array>
                    </dict>
                </array>
                <key>PayloadDisplayName</key>
                <string>AirplaneMode Relay</string>
                <key>PayloadIdentifier</key>
                <string>com.airplanemode.relay</string>
                <key>PayloadType</key>
                <string>Configuration</string>
                <key>PayloadUUID</key>
                <string>\(uuid)</string>
                <key>PayloadVersion</key>
                <integer>1</integer>
                <key>PayloadScope</key>
                <string>System</string>
                <key>PayloadRemovalDisallowed</key>
                <false/>
            </dict>
            </plist>
            """
        return Data(xml.utf8)
    }

    /// Discovers the local hostname via `scutil --get LocalHostName`.
    public static func localHostname() -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--get", "LocalHostName"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let hostname = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "localhost"
            return hostname.isEmpty ? "localhost" : hostname
        } catch {
            return "localhost"
        }
    }

    /// Writes the profile to a temp file and returns its path.
    public static func writeToTempFile(hostname: String, port: Int, matchDomains: [String] = []) throws -> URL {
        let data = generate(hostname: hostname, port: port, matchDomains: matchDomains)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("airplanemode-relay.mobileconfig")
        try data.write(to: url)
        return url
    }

    /// Opens the mobileconfig via System Settings for user approval.
    /// Skips reinstall if the profile is already active with the same domains.
    /// Returns a description of why the profile was reinstalled, or nil if skipped.
    @discardableResult
    public static func installProfile(hostname: String, port: Int, matchDomains: [String] = []) throws -> String? {
        // Check if the currently installed profile already matches
        let previousDomains = installedDomains()
        if previousDomains != nil, previousDomains! == matchDomains {
            return nil // skip — same domains already installed
        }

        let url = try writeToTempFile(hostname: hostname, port: port, matchDomains: matchDomains)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.path]
        try process.run()
        process.waitUntilExit()

        // Persist which domains are installed (survives stop/start cycles)
        saveInstalledDomains(matchDomains)

        // Build reason string
        if let prev = previousDomains {
            let from = prev.isEmpty ? "system-wide" : prev.joined(separator: ", ")
            let to = matchDomains.isEmpty ? "system-wide" : matchDomains.joined(separator: ", ")
            return "Domains changed: \(from) → \(to)"
        }
        return "First install"
    }

    // MARK: - Installed domains persistence

    private static var installedDomainsURL: URL {
        SetupManager.supportDir.appendingPathComponent("installed-domains.json")
    }

    /// Returns the domains from the currently installed profile, or nil if no profile is installed.
    public static func installedDomains() -> [String]? {
        guard let data = try? Data(contentsOf: installedDomainsURL),
              let domains = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return domains
    }

    private static func saveInstalledDomains(_ domains: [String]) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: SetupManager.supportDir.path) {
            try? fm.createDirectory(at: SetupManager.supportDir, withIntermediateDirectories: true)
        }
        try? JSONEncoder().encode(domains).write(to: installedDomainsURL)
    }

    /// Whether a profile is currently installed (based on persisted domains file).
    public static var isProfileActive: Bool {
        installedDomains() != nil
    }

    /// Checks if the AirplaneMode relay profile is currently installed.
    /// System-scoped profiles aren't visible to `profiles list` without root,
    /// so we probe the relay to see if traffic is actually being routed through it.
    public static func isProfileInstalled() -> Bool {
        // User-scoped profiles are visible without root
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/profiles")
        process.arguments = ["list"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if output.contains("com.airplanemode.relay") { return true }
        } catch {}
        return false
    }

    /// Checks if the relay is actually receiving routed traffic by looking at packet count.
    /// More reliable than profile listing for system-scoped profiles.
    public static func isRoutingActive(client: RelayClient) async -> Bool {
        guard let stats = try? await client.getStats() else { return false }
        return stats.packetsTotal > 0
    }

    /// Removes the installed mobileconfig profile.
    /// System-scoped profiles require root, so we use an AppleScript privilege prompt.
    @discardableResult
    public static func removeProfile() -> Bool {
        // Try user-scoped removal first (no root)
        if runProfilesRemove(sudo: false) {
            try? FileManager.default.removeItem(at: installedDomainsURL)
            return true
        }
        // System-scoped profiles need root — prompt via AppleScript
        if runProfilesRemove(sudo: true) {
            try? FileManager.default.removeItem(at: installedDomainsURL)
            return true
        }
        try? FileManager.default.removeItem(at: installedDomainsURL)
        return false
    }

    private static func runProfilesRemove(sudo: Bool) -> Bool {
        let process = Process()
        if sudo {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e",
                "do shell script \"/usr/bin/profiles remove -identifier com.airplanemode.relay\" with administrator privileges",
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/profiles")
            process.arguments = ["remove", "-identifier", "com.airplanemode.relay"]
        }
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
}
