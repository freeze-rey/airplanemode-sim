import Foundation
import Testing
@testable import AirplaneModeCore

// MARK: - Bandwidth Conversion Tests

/// The custom profile UI accepts "Kbps" (kilobits per second) from the user
/// and converts to bytes/sec for the relay: (kbps * 1000) / 8.
/// "Kbps" means kilobits, not kilobytes.
@Suite("Bandwidth Conversion")
struct BandwidthConversionTests {

    @Test("100 Kbps = 12500 bytes/sec")
    func hundredKbps() {
        let kbps = 100
        let bytesPerSec = kbps * 1000 / 8
        #expect(bytesPerSec == 12_500)
    }

    @Test("690 Kbps = 86250 bytes/sec (poor profile bandwidth)")
    func poorProfileBandwidth() {
        let kbps = 690
        let bytesPerSec = kbps * 1000 / 8
        #expect(bytesPerSec == 86_250)
    }

    @Test("0 Kbps = 0 bytes/sec (unlimited)")
    func zeroKbpsUnlimited() {
        let kbps = 0
        let bytesPerSec = kbps * 1000 / 8
        #expect(bytesPerSec == 0)
    }

    @Test("NetworkProfile encodes bandwidthBps correctly for relay")
    func networkProfileEncoding() throws {
        // Simulate what applyCustomProfile does: user enters "100" Kbps
        let inputKbps = 100
        let profile = NetworkProfile(
            name: "Test",
            latencyMs: 0,
            jitterMeanMs: 0,
            jitterP99Ms: 0,
            packetLoss: 0,
            burstLen: 0,
            bandwidthBps: inputKbps * 1000 / 8
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(NetworkProfile.self, from: data)

        // 100 Kbps -> 12500 bytes/sec
        #expect(decoded.bandwidthBps == 12_500)
    }

    @Test("packetLoss percentage conversion (user enters %, API expects 0..1)")
    func packetLossConversion() throws {
        // User enters "5" (meaning 5%), code divides by 100
        let inputPercent = 5.0
        let apiValue = inputPercent / 100.0

        let profile = NetworkProfile(
            name: "Test",
            latencyMs: 0,
            jitterMeanMs: 0,
            jitterP99Ms: 0,
            packetLoss: apiValue,
            burstLen: 0,
            bandwidthBps: 0
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(NetworkProfile.self, from: data)
        #expect(decoded.packetLoss == 0.05)
    }
}
