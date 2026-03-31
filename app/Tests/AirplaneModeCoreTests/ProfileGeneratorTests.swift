import Foundation
import Testing
@testable import AirplaneModeCore

// MARK: - ProfileGenerator Tests

@Suite("ProfileGenerator")
struct ProfileGeneratorTests {

    @Test("generates valid XML plist with correct PayloadIdentifier")
    func payloadIdentifier() throws {
        let data = ProfileGenerator.generate(hostname: "test-mac", port: 4433)
        let xml = String(data: data, encoding: .utf8)!

        // Parse as XML plist to verify well-formedness
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        let dict = try #require(plist as? [String: Any])

        // Top-level PayloadIdentifier
        #expect(dict["PayloadIdentifier"] as? String == "com.airplanemode.relay")

        // Inner payload PayloadIdentifier
        let content = try #require(dict["PayloadContent"] as? [[String: Any]])
        #expect(content.count == 1)
        let inner = content[0]
        #expect(inner["PayloadIdentifier"] as? String == "com.airplanemode.relay.config")

        // PayloadType for relay
        #expect(inner["PayloadType"] as? String == "com.apple.relay.managed")

        // Top-level PayloadType
        #expect(dict["PayloadType"] as? String == "Configuration")

        // PayloadDisplayName
        #expect(dict["PayloadDisplayName"] as? String == "AirplaneMode Relay")

        // PayloadRemovalDisallowed should be false
        #expect(dict["PayloadRemovalDisallowed"] as? Bool == false)

        // Well-formed XML header
        #expect(xml.contains("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
    }

    @Test("HTTP3RelayURL contains hostname and port")
    func relayURL() throws {
        let data = ProfileGenerator.generate(hostname: "my-laptop", port: 9999)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as! [String: Any]

        let content = (plist["PayloadContent"] as! [[String: Any]])[0]
        let relays = try #require(content["Relays"] as? [[String: Any]])
        #expect(relays.count == 1)
        let relayURL = try #require(relays[0]["HTTP3RelayURL"] as? String)
        #expect(relayURL == "https://my-laptop.local:9999/")
    }

    @Test("generates two distinct UUIDs")
    func distinctUUIDs() throws {
        let data = ProfileGenerator.generate(hostname: "test", port: 4433)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as! [String: Any]

        let outerUUID = try #require(plist["PayloadUUID"] as? String)
        let content = (plist["PayloadContent"] as! [[String: Any]])[0]
        let innerUUID = try #require(content["PayloadUUID"] as? String)

        #expect(outerUUID != innerUUID, "Outer and inner PayloadUUIDs must be distinct")
        // Verify they look like UUIDs (36 chars with hyphens)
        #expect(outerUUID.count == 36)
        #expect(innerUUID.count == 36)
    }

    @Test("MatchDomains is empty array (matches all domains)")
    func matchDomainsEmpty() throws {
        let data = ProfileGenerator.generate(hostname: "test", port: 4433)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as! [String: Any]

        let content = (plist["PayloadContent"] as! [[String: Any]])[0]
        let matchDomains = try #require(content["MatchDomains"] as? [Any])
        #expect(matchDomains.isEmpty)
    }

    @Test("sanitizes hostname with special characters")
    func hostnameSanitization() throws {
        // Hostname with XML-injection characters should be sanitized
        let data = ProfileGenerator.generate(hostname: "test<script>", port: 4433)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as! [String: Any]

        let content = (plist["PayloadContent"] as! [[String: Any]])[0]
        let relays = (content["Relays"] as! [[String: Any]])[0]
        let url = relays["HTTP3RelayURL"] as! String
        // Special characters should be stripped, leaving only "testscript"
        #expect(url == "https://testscript.local:4433/")
    }

    @Test("empty hostname falls back to localhost")
    func emptyHostnameFallback() throws {
        let data = ProfileGenerator.generate(hostname: "", port: 4433)
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as! [String: Any]

        let content = (plist["PayloadContent"] as! [[String: Any]])[0]
        let relays = (content["Relays"] as! [[String: Any]])[0]
        let url = relays["HTTP3RelayURL"] as! String
        #expect(url == "https://localhost.local:4433/")
    }
}
