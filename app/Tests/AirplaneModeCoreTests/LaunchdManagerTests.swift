import Foundation
import Testing
@testable import AirplaneModeCore

@Suite("LaunchdManager")
struct LaunchdManagerTests {

    // MARK: - Plist generation

    @Test("generates valid XML plist with correct Label and Program")
    func plistLabelAndProgram() throws {
        let data = LaunchdManager.generatePlist(
            label: "com.airplanemode.relay",
            program: "/usr/local/bin/airplanemode-relay",
            environment: ["CERT_FILE": "/tmp/cert.pem"],
            logPath: "/tmp/relay.log"
        )

        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        let dict = try #require(plist as? [String: Any])

        #expect(dict["Label"] as? String == "com.airplanemode.relay")
        #expect(dict["Program"] as? String == "/usr/local/bin/airplanemode-relay")
        #expect(dict["RunAtLoad"] as? Bool == true)
        #expect(dict["KeepAlive"] as? Bool == false)
    }

    @Test("plist includes environment variables")
    func plistEnvironment() throws {
        let data = LaunchdManager.generatePlist(
            label: "com.airplanemode.relay",
            program: "/bin/test",
            environment: [
                "CERT_FILE": "/path/to/cert.pem",
                "KEY_FILE": "/path/to/key.pem",
                "RELAY_HOST": "my-mac",
            ],
            logPath: "/tmp/relay.log"
        )

        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        let dict = try #require(plist as? [String: Any])
        let env = try #require(dict["EnvironmentVariables"] as? [String: String])

        #expect(env["CERT_FILE"] == "/path/to/cert.pem")
        #expect(env["KEY_FILE"] == "/path/to/key.pem")
        #expect(env["RELAY_HOST"] == "my-mac")
    }

    @Test("plist log paths are set correctly")
    func plistLogPaths() throws {
        let logPath = "/Users/test/Library/Application Support/AirplaneMode/relay.log"
        let data = LaunchdManager.generatePlist(
            label: "com.airplanemode.relay",
            program: "/bin/test",
            environment: [:],
            logPath: logPath
        )

        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        let dict = try #require(plist as? [String: Any])

        #expect(dict["StandardOutPath"] as? String == logPath)
        #expect(dict["StandardErrorPath"] as? String == logPath)
    }

    // MARK: - PID parsing

    @Test("parsePID extracts PID from launchctl print output")
    func parsePIDFromOutput() {
        let output = """
        com.airplanemode.relay = {
            active count = 1
            path = /Users/test/Library/LaunchAgents/com.airplanemode.relay.plist
            type = gui
            state = running

            program = /usr/local/bin/airplanemode-relay
            pid = 12345
            last exit code = 0

            properties = keepalive
        }
        """
        #expect(LaunchdManager.parsePID(from: output) == 12345)
    }

    @Test("parsePID returns nil when no pid line present")
    func parsePIDMissing() {
        let output = """
        com.airplanemode.relay = {
            active count = 0
            state = not running
        }
        """
        #expect(LaunchdManager.parsePID(from: output) == nil)
    }

    @Test("parsePID handles empty output")
    func parsePIDEmpty() {
        #expect(LaunchdManager.parsePID(from: "") == nil)
    }

    // MARK: - State file round-trip

    @Test("DaemonState encodes and decodes correctly")
    func stateRoundTrip() throws {
        let original = DaemonState(
            profile: "moderate",
            domains: ["facebook.com", "instagram.com"],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DaemonState.self, from: data)

        #expect(decoded.profile == original.profile)
        #expect(decoded.domains == original.domains)
        #expect(decoded.startedAt == original.startedAt)
    }

    @Test("DaemonState handles empty domains")
    func stateEmptyDomains() throws {
        let original = DaemonState(
            profile: "terrible",
            domains: [],
            startedAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DaemonState.self, from: data)

        #expect(decoded.domains.isEmpty)
        #expect(decoded.profile == "terrible")
    }

    // MARK: - Plist URL

    @Test("plist URL points to LaunchAgents directory")
    func plistPath() {
        let path = LaunchdManager.plistURL.path
        #expect(path.contains("Library/LaunchAgents"))
        #expect(path.hasSuffix("com.airplanemode.relay.plist"))
    }

    // MARK: - Service label

    @Test("service label is consistent")
    func serviceLabel() {
        #expect(LaunchdManager.serviceLabel == "com.airplanemode.relay")
    }
}
