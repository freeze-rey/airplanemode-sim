package netsim

import (
	"fmt"
	"math"
	"sort"
	"strings"
	"testing"
	"time"
)

// TestLogNormalDistributionShape verifies the delay distribution is actually
// log-normal by comparing empirical quantiles against the theoretical CDF.
func TestLogNormalDistributionShape(t *testing.T) {
	p := Profiles["turkish-air"]

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

	t.Logf("Log-normal params: mu=%.3f sigma=%.3f median_jitter=%.1fms", mu, sigma, median)

	theoreticalQuantile := func(quantile float64) float64 {
		z := normalInverseCDF(quantile)
		jitter := math.Exp(mu + sigma*z)
		delay := float64(p.LatencyMs) + jitter - median
		if delay < 0 {
			delay = 0
		}
		return delay
	}

	const n = 100_000
	samples := make([]float64, n)
	for i := 0; i < n; i++ {
		samples[i] = float64(p.ComputeDelay().Milliseconds())
	}
	sort.Float64s(samples)

	quantiles := []float64{0.01, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99}
	t.Logf("\n%-10s %10s %10s %10s", "Quantile", "Empirical", "Theory", "Error%")
	t.Logf("%-10s %10s %10s %10s", "--------", "---------", "------", "------")

	maxError := 0.0
	for _, q := range quantiles {
		idx := int(float64(n) * q)
		if idx >= n {
			idx = n - 1
		}
		empirical := samples[idx]
		theoretical := theoreticalQuantile(q)
		errPct := 0.0
		if theoretical > 0 {
			errPct = math.Abs(empirical-theoretical) / theoretical * 100
		}
		if errPct > maxError {
			maxError = errPct
		}
		t.Logf("P%-9.0f %8.0fms %8.0fms %9.1f%%", q*100, empirical, theoretical, errPct)
	}

	if maxError > 5.0 {
		t.Errorf("max quantile error = %.1f%%, expected < 5%% — distribution may not be log-normal", maxError)
	}

	t.Log("\nDelay histogram (Turkish Air, 100k samples):")
	printHistogram(t, samples, 20, float64(p.LatencyMs)*3)
}

// TestOneWayDelayThroughSimConn verifies that delays observed through the
// actual SimConn UDP path match the same log-normal distribution.
func TestOneWayDelayThroughSimConn(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(receiver)
	defer sim.Close()

	profile := NetworkProfile{
		Name: "ShapeTest", LatencyMs: 20, JitterMeanMs: 5, JitterP99Ms: 30,
		PacketLoss: 0, BurstLen: 0, BandwidthBps: 0,
	}
	sim.SetProfile(`{"name":"ShapeTest","latencyMs":20,"jitterMeanMs":5,"jitterP99Ms":30,"packetLoss":0,"burstLen":0,"bandwidthBps":0}`)

	const n = 500
	delays := make([]float64, n)

	for i := 0; i < n; i++ {
		msg := []byte(fmt.Sprintf("p%d", i))
		t0 := wallClock()
		sender.WriteTo(msg, receiver.LocalAddr())
		buf := make([]byte, 64)
		sim.ReadFrom(buf)
		delays[i] = msSince(t0)
	}

	sort.Float64s(delays)
	var sum float64
	for _, d := range delays {
		sum += d
	}
	median := delays[n/2]
	p25 := delays[n/4]
	p75 := delays[3*n/4]
	p90 := delays[int(float64(n)*0.90)]
	p99 := delays[int(float64(n)*0.99)]
	mean := sum / float64(n)

	t.Logf("SimConn one-way delay (n=%d, 20ms base + jitter):", n)
	t.Logf("  p25=%.0fms  median=%.0fms  p75=%.0fms  p90=%.0fms  p99=%.0fms  mean=%.0fms",
		p25, median, p75, p90, p99, mean)

	if mean <= median {
		t.Errorf("mean (%.0f) should be > median (%.0f) for right-skewed log-normal", mean, median)
	}
	if median < 15 || median > 30 {
		t.Errorf("median = %.0fms, expected near 20ms base", median)
	}
	tailRatio := p99 / median
	t.Logf("  tail ratio (p99/median) = %.1f (log-normal expects >> 1)", tailRatio)
	if tailRatio < 1.5 {
		t.Errorf("tail ratio %.1f too low — distribution is not heavy-tailed", tailRatio)
	}
	if delays[0] < 0 {
		t.Errorf("min delay = %.0fms, expected >= 0", delays[0])
	}

	lnMean := math.Log(float64(profile.JitterMeanMs))
	lnP99 := math.Log(float64(profile.JitterP99Ms))
	delta := lnP99 - lnMean
	disc := 4.652*4.652 - 4*2*delta
	if disc < 0 {
		disc = 0
	}
	sigma := (4.652 - math.Sqrt(disc)) / 2
	mu := lnMean - sigma*sigma/2
	jitterMedian := math.Exp(mu)

	quantiles := []float64{0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99}
	t.Logf("\n%-10s %10s %10s %10s", "Quantile", "Empirical", "Theory", "Error%")
	maxError := 0.0
	for _, q := range quantiles {
		idx := int(float64(n) * q)
		if idx >= n {
			idx = n - 1
		}
		empirical := delays[idx]

		z := normalInverseCDF(q)
		jitter := math.Exp(mu + sigma*z)
		theoretical := float64(profile.LatencyMs) + jitter - jitterMedian
		if theoretical < 0 {
			theoretical = 0
		}

		errPct := 0.0
		if theoretical > 0 {
			errPct = math.Abs(empirical-theoretical) / theoretical * 100
		}
		if errPct > maxError {
			maxError = errPct
		}
		t.Logf("P%-9.0f %8.0fms %8.0fms %9.1f%%", q*100, empirical, theoretical, errPct)
	}

	if maxError > 20.0 {
		t.Errorf("max quantile error = %.1f%%, expected < 20%% — SimConn may distort distribution", maxError)
	}

	t.Log("\nSimConn delay histogram:")
	printHistogram(t, delays, 15, 60)
}

// ---- helpers ----

func normalInverseCDF(p float64) float64 {
	if p <= 0 {
		return math.Inf(-1)
	}
	if p >= 1 {
		return math.Inf(1)
	}
	if p == 0.5 {
		return 0
	}

	var x float64
	if p < 0.5 {
		x = p
	} else {
		x = 1 - p
	}

	ln := math.Sqrt(-2 * math.Log(x))

	c0 := 2.515517
	c1 := 0.802853
	c2 := 0.010328
	d1 := 1.432788
	d2 := 0.189269
	d3 := 0.001308

	result := ln - (c0+c1*ln+c2*ln*ln)/(1+d1*ln+d2*ln*ln+d3*ln*ln*ln)

	if p < 0.5 {
		return -result
	}
	return result
}

func printHistogram(t *testing.T, samples []float64, buckets int, maxVal float64) {
	t.Helper()
	counts := make([]int, buckets)
	bucketWidth := maxVal / float64(buckets)

	for _, s := range samples {
		idx := int(s / bucketWidth)
		if idx >= buckets {
			idx = buckets - 1
		}
		if idx < 0 {
			idx = 0
		}
		counts[idx]++
	}

	maxCount := 0
	for _, c := range counts {
		if c > maxCount {
			maxCount = c
		}
	}

	barWidth := 50
	for i, c := range counts {
		lo := float64(i) * bucketWidth
		hi := lo + bucketWidth
		bar := int(float64(c) / float64(maxCount) * float64(barWidth))
		t.Logf("  %4.0f-%4.0fms |%s %d", lo, hi, strings.Repeat("█", bar), c)
	}
}

func wallClock() int64 {
	return time.Now().UnixNano()
}

func msSince(start int64) float64 {
	return float64(time.Now().UnixNano()-start) / 1e6
}
