package netsim

import (
	"math"
	"sync"
	"time"
)

// Stats holds a snapshot of simulation statistics.
type Stats struct {
	ReadPackets  int64
	ReadBytes    int64
	ReadDropped  int64 // packets dropped by configured packet loss
	ReadOverflow int64 // packets dropped by readyCh buffer overflow
	WritePackets int64
	WriteBytes   int64
	WriteDropped int64
}

// delayStats computes running mean and standard deviation of packet delays
// using Welford's online algorithm. Numerically stable, no overflow risk.
//
// Reset at each snapshot() call so each poll interval gets independent stats.
type delayStats struct {
	mu    sync.Mutex
	count int64
	mean  float64 // running mean (nanoseconds)
	m2    float64 // sum of squared deviations from running mean
}

// record adds a delay sample using Welford's online update.
func (ds *delayStats) record(d time.Duration) {
	ns := float64(d.Nanoseconds())
	ds.mu.Lock()
	ds.count++
	delta := ns - ds.mean
	ds.mean += delta / float64(ds.count)
	delta2 := ns - ds.mean
	ds.m2 += delta * delta2
	ds.mu.Unlock()
}

// snapshot returns interval stats and resets for the next interval.
func (ds *delayStats) snapshot() (count int64, meanNanos float64, stddevNanos float64) {
	ds.mu.Lock()
	count = ds.count
	meanNanos = ds.mean
	if count > 1 {
		stddevNanos = math.Sqrt(ds.m2 / float64(count))
	}
	ds.count = 0
	ds.mean = 0
	ds.m2 = 0
	ds.mu.Unlock()
	return
}
