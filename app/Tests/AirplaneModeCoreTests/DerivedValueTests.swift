import Foundation
import Testing
@testable import AirplaneModeCore

@Suite("Core Type Tests")
struct CoreTypeTests {

    // MARK: - PresetProfile

    @Test("preset profile IDs match Go relay keys")
    func presetProfileIDs() {
        let expectedIDs = ["none", "starlink", "jetblue", "american", "turkish-air"]
        let actualIDs = PresetProfile.allCases.map(\.rawValue)
        #expect(actualIDs == expectedIDs)
    }

    @Test("preset display names are human-readable")
    func presetDisplayNames() {
        #expect(PresetProfile.none.displayName == "None")
        #expect(PresetProfile.starlink.displayName == "Starlink")
        #expect(PresetProfile.jetblue.displayName == "JetBlue")
        #expect(PresetProfile.american.displayName == "American")
        #expect(PresetProfile.turkishAir.displayName == "Turkish Air")
    }

    @Test("none preset has empty latency label")
    func noneLatencyLabel() {
        #expect(PresetProfile.none.latencyLabel == "")
    }

    @Test("non-none presets have approximate latency labels")
    func nonNoneLatencyLabels() {
        #expect(PresetProfile.starlink.latencyLabel == "~50ms")
        #expect(PresetProfile.jetblue.latencyLabel == "~296ms")
        #expect(PresetProfile.american.latencyLabel == "~358ms")
        #expect(PresetProfile.turkishAir.latencyLabel == "~435ms")
    }

    // MARK: - MetricsSnapshot JSON round-trip

    @Test("MetricsSnapshot decodes from relay-format JSON")
    func metricsSnapshotDecoding() throws {
        let json = """
        {
            "timestamp": 1710700000000,
            "latencyMs": 435,
            "jitterMs": 177,
            "throughputBytesPerSec": 86250,
            "drops": 3,
            "packetsTotal": 500,
            "profileName": "Turkish Air",
            "idle": false
        }
        """
        let data = Data(json.utf8)
        let snapshot = try JSONDecoder().decode(MetricsSnapshot.self, from: data)

        #expect(snapshot.timestamp == 1710700000000)
        #expect(snapshot.latencyMs == 435)
        #expect(snapshot.jitterMs == 177)
        #expect(snapshot.throughputBytesPerSec == 86250)
        #expect(snapshot.drops == 3)
        #expect(snapshot.packetsTotal == 500)
        #expect(snapshot.profileName == "Turkish Air")
        #expect(snapshot.idle == false)
    }

    // MARK: - NetworkProfile encoding

    @Test("NetworkProfile encodes to JSON matching Go relay format")
    func networkProfileEncoding() throws {
        let profile = NetworkProfile(
            name: "Custom",
            latencyMs: 100,
            jitterMeanMs: 20,
            jitterP99Ms: 150,
            packetLoss: 0.05,
            burstLen: 2,
            bandwidthBps: 50000
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(NetworkProfile.self, from: data)
        #expect(decoded.name == "Custom")
        #expect(decoded.latencyMs == 100)
        #expect(decoded.bandwidthBps == 50000)
    }
}
