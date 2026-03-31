import Foundation

/// Mirrors the Go relay's NetworkProfile struct.
public struct NetworkProfile: Codable, Sendable {
    public let name: String
    public let latencyMs: Int
    public let jitterMeanMs: Int
    public let jitterP99Ms: Int
    public let packetLoss: Double
    public let burstLen: Int
    public let bandwidthBps: Int

    public init(name: String, latencyMs: Int, jitterMeanMs: Int, jitterP99Ms: Int,
                packetLoss: Double, burstLen: Int, bandwidthBps: Int) {
        self.name = name
        self.latencyMs = latencyMs
        self.jitterMeanMs = jitterMeanMs
        self.jitterP99Ms = jitterP99Ms
        self.packetLoss = packetLoss
        self.burstLen = burstLen
        self.bandwidthBps = bandwidthBps
    }
}

/// Mirrors the Go relay's metricsSnapshot struct.
public struct MetricsSnapshot: Codable, Sendable {
    public let timestamp: Int64
    public let latencyMs: Int
    public let jitterMs: Int
    public let throughputBytesPerSec: Int
    public let drops: Int
    public let packetsTotal: Int
    public let profileName: String
    public let idle: Bool
}

/// Preset profile identifiers matching the Go relay's Profiles map.
public enum PresetProfile: String, CaseIterable, Sendable {
    case none
    case starlink
    case jetblue
    case american
    case turkishAir = "turkish-air"

    public var displayName: String {
        switch self {
        case .none: "None"
        case .starlink: "Starlink"
        case .jetblue: "JetBlue"
        case .american: "American"
        case .turkishAir: "Turkish Air"
        }
    }

    public var latencyLabel: String {
        switch self {
        case .none: ""
        case .starlink: "~50ms"
        case .jetblue: "~296ms"
        case .american: "~358ms"
        case .turkishAir: "~435ms"
        }
    }

    /// Full profile spec mirroring the Go relay's Profiles map.
    public var profile: NetworkProfile {
        switch self {
        case .none:
            NetworkProfile(name: "None", latencyMs: 0, jitterMeanMs: 0, jitterP99Ms: 0, packetLoss: 0, burstLen: 0, bandwidthBps: 0)
        case .starlink:
            NetworkProfile(name: "Starlink", latencyMs: 50, jitterMeanMs: 15, jitterP99Ms: 80, packetLoss: 0.01, burstLen: 0, bandwidthBps: 500_000)
        case .jetblue:
            NetworkProfile(name: "JetBlue", latencyMs: 296, jitterMeanMs: 90, jitterP99Ms: 1050, packetLoss: 0.005, burstLen: 0, bandwidthBps: 416_660)
        case .american:
            NetworkProfile(name: "American", latencyMs: 358, jitterMeanMs: 121, jitterP99Ms: 763, packetLoss: 0.005, burstLen: 0, bandwidthBps: 523_000)
        case .turkishAir:
            NetworkProfile(name: "Turkish Air", latencyMs: 435, jitterMeanMs: 177, jitterP99Ms: 2300, packetLoss: 0.005, burstLen: 0, bandwidthBps: 86_250)
        }
    }
}
