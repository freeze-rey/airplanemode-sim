package netsim

import (
	"encoding/json"
	"math"
	"math/rand"
	"time"
)

// NetworkProfile defines network condition simulation parameters.
// Each field maps to a measurable network characteristic.
type NetworkProfile struct {
	Name         string  `json:"name"`
	LatencyMs    int     `json:"latencyMs"`    // base one-way latency
	JitterMeanMs int     `json:"jitterMeanMs"` // mean jitter (log-normal distribution)
	JitterP99Ms  int     `json:"jitterP99Ms"`  // 99th percentile jitter
	PacketLoss   float64 `json:"packetLoss"`   // 0..1, applied to all UDP packets
	BurstLen     int     `json:"burstLen"`     // consecutive drops after a loss event
	BandwidthBps int     `json:"bandwidthBps"` // max bytes/sec (0=unlimited)
}

// Profiles contains preset network profiles calibrated from real-world measurements.
//
// Turkish-Air: calibrated from Turkish Airlines JFK-IST benchmark (Panasonic eXConnect GEO Ku-band).
//
//	435ms = half of 870ms median RTT to Anthropic (TLS handshake timing).
//	177ms mean jitter, 2300ms P99 -> log-normal(mu=3.56, sigma=1.80).
//	86250 B/s = 690 Kbps (0.69 Mbps median download).
//	0.5% loss: research-based estimate for GEO Ku-band UDP.
//
// JetBlue: calibrated from JetBlue domestic US flight (Viasat Ka-band, CF PoP: DEN).
//
//	296ms = half of 593ms median CF TLS (cruise traces 3-6, steady-state).
//	90ms mean jitter, 1050ms P99 -> log-normal(mu=3.19, sigma=1.62).
//	416660 B/s = 3.33 Mbps median download.
//	0.5% loss: research-based estimate.
// American: calibrated from American Airlines LGA-EYW (AA4662, E175, Intelsat GEO regional Wi-Fi).
//
//	358ms = half of 715ms median IAD TLS (after-takeoff traces 3-6, n=80).
//	121ms mean jitter, 763ms P99 -> log-normal(mu=-2.63, sigma=1.01).
//	523000 B/s = 4.2 Mbps avg download.
//	0.5% loss: research-based estimate for GEO satellite UDP.
var Profiles = map[string]NetworkProfile{
	"none":        {Name: "None", LatencyMs: 0, JitterMeanMs: 0, JitterP99Ms: 0, PacketLoss: 0, BurstLen: 0, BandwidthBps: 0},
	"starlink":    {Name: "Starlink", LatencyMs: 50, JitterMeanMs: 15, JitterP99Ms: 80, PacketLoss: 0.01, BurstLen: 0, BandwidthBps: 500_000},
	"jetblue":     {Name: "JetBlue", LatencyMs: 296, JitterMeanMs: 90, JitterP99Ms: 1050, PacketLoss: 0.005, BurstLen: 0, BandwidthBps: 416_660},
	"american":    {Name: "American", LatencyMs: 358, JitterMeanMs: 121, JitterP99Ms: 763, PacketLoss: 0.005, BurstLen: 0, BandwidthBps: 523_000},
	"turkish-air": {Name: "Turkish Air", LatencyMs: 435, JitterMeanMs: 177, JitterP99Ms: 2300, PacketLoss: 0.005, BurstLen: 0, BandwidthBps: 86_250},
}

// ComputeDelay returns one-way latency + log-normal jitter for this profile.
//
// Jitter follows a log-normal distribution parameterized by JitterMeanMs and JitterP99Ms.
// Real satellite WiFi exhibits heavy-tailed jitter: most packets arrive near base latency,
// with occasional large spikes.
//
// Derivation: From E[X] = exp(mu + sigma^2/2) = JitterMeanMs and
// P99 = exp(mu + 2.326*sigma) = JitterP99Ms, solve the quadratic
// sigma^2 - 4.652*sigma + 2*(ln(P99) - ln(mean)) = 0, then mu = ln(mean) - sigma^2/2.
func (p NetworkProfile) ComputeDelay() time.Duration {
	if p.LatencyMs == 0 && p.JitterMeanMs == 0 {
		return 0
	}
	if p.JitterMeanMs == 0 || p.JitterP99Ms == 0 {
		return time.Duration(p.LatencyMs) * time.Millisecond
	}

	lnMean := math.Log(float64(p.JitterMeanMs))
	lnP99 := math.Log(float64(p.JitterP99Ms))
	delta := lnP99 - lnMean
	disc := 4.652*4.652 - 4*2*delta
	if disc < 0 {
		disc = 0
	}
	sigma := (4.652 - math.Sqrt(disc)) / 2
	mu := lnMean - sigma*sigma/2
	median := math.Exp(mu)

	jitter := math.Exp(mu + sigma*rand.NormFloat64())
	ms := float64(p.LatencyMs) + jitter - median
	if ms < 0 {
		ms = 0
	}
	return time.Duration(ms * float64(time.Millisecond))
}

// IsPassthrough returns true when this profile applies no simulation.
func (p NetworkProfile) IsPassthrough() bool {
	return p.LatencyMs == 0 && p.JitterMeanMs == 0 && p.PacketLoss == 0 && p.BandwidthBps == 0
}

// ResolveProfile looks up a preset by name or parses a JSON custom profile.
// Returns the profile and true if resolved, or zero value and false if not found.
func ResolveProfile(id string) (NetworkProfile, bool) {
	if len(id) > 0 && id[0] == '{' {
		var custom NetworkProfile
		if json.Unmarshal([]byte(id), &custom) == nil {
			return custom, true
		}
		return NetworkProfile{}, false
	}
	p, ok := Profiles[id]
	return p, ok
}
