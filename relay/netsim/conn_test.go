package netsim

import (
	"fmt"
	"math"
	"net"
	"sort"
	"sync"
	"syscall"
	"testing"
	"time"

	"golang.org/x/net/ipv4"
)

// Compile-time assertions: SimConn satisfies quic-go's OOBCapablePacketConn
// and batchConn interfaces. quic-go's types are unexported, so we assert the
// structural equivalent.
var _ interface {
	net.PacketConn
	SyscallConn() (syscall.RawConn, error)
	SetReadBuffer(int) error
	ReadMsgUDP(b, oob []byte) (n, oobn, flags int, addr *net.UDPAddr, err error)
	WriteMsgUDP(b, oob []byte, addr *net.UDPAddr) (n, oobn int, err error)
} = (*SimConn)(nil)

var _ interface {
	ReadBatch(ms []ipv4.Message, flags int) (int, error)
} = (*SimConn)(nil)

// ============================================================================
// Profile unit tests (pure math, no network)
// ============================================================================

func TestComputeDelayNoneProfile(t *testing.T) {
	p := Profiles["none"]
	for i := 0; i < 100; i++ {
		if d := p.ComputeDelay(); d != 0 {
			t.Fatalf("expected 0 delay for none profile, got %v on iteration %d", d, i)
		}
	}
}

func TestComputeDelayTurkishAirDistribution(t *testing.T) {
	p := Profiles["turkish-air"]

	const n = 50000
	samples := make([]float64, n)
	var sum float64
	for i := 0; i < n; i++ {
		ms := float64(p.ComputeDelay().Milliseconds())
		samples[i] = ms
		sum += ms
	}

	sort.Float64s(samples)
	median := samples[n/2]
	p99 := samples[int(float64(n)*0.99)]
	mean := sum / float64(n)

	if math.Abs(median-435) > 435*0.05 {
		t.Errorf("median = %.1fms, expected ~435ms (+-5%%)", median)
	}
	if p99 < 2000 || p99 > 3000 {
		t.Errorf("P99 = %.1fms, expected in [2000, 3000]", p99)
	}
	if mean < 500 || mean > 650 {
		t.Errorf("mean = %.1fms, expected in [500, 650]", mean)
	}

	t.Logf("Turkish Air distribution: median=%.0fms mean=%.0fms p99=%.0fms", median, mean, p99)
}

func TestComputeDelayJetBlueDistribution(t *testing.T) {
	p := Profiles["jetblue"]

	const n = 50000
	samples := make([]float64, n)
	var sum float64
	for i := 0; i < n; i++ {
		ms := float64(p.ComputeDelay().Milliseconds())
		samples[i] = ms
		sum += ms
	}

	sort.Float64s(samples)
	median := samples[n/2]
	p99 := samples[int(float64(n)*0.99)]
	mean := sum / float64(n)

	if math.Abs(median-296) > 296*0.05 {
		t.Errorf("median = %.1fms, expected ~296ms (+-5%%)", median)
	}
	if p99 < 1000 || p99 > 1600 {
		t.Errorf("P99 = %.1fms, expected in [1000, 1600]", p99)
	}
	if mean < 340 || mean > 420 {
		t.Errorf("mean = %.1fms, expected in [340, 420]", mean)
	}

	t.Logf("JetBlue distribution: median=%.0fms mean=%.0fms p99=%.0fms", median, mean, p99)
}

func TestResolveProfileJSON(t *testing.T) {
	p, ok := ResolveProfile(`{"name":"Custom","latencyMs":100,"bandwidthBps":50000}`)
	if !ok {
		t.Fatal("expected custom JSON to resolve")
	}
	if p.LatencyMs != 100 || p.BandwidthBps != 50000 {
		t.Errorf("unexpected profile: %+v", p)
	}
}

func TestResolveProfilePreset(t *testing.T) {
	p, ok := ResolveProfile("turkish-air")
	if !ok {
		t.Fatal("expected preset to resolve")
	}
	if p.LatencyMs != 435 {
		t.Errorf("expected 435ms latency, got %d", p.LatencyMs)
	}
}

// ============================================================================
// UDP-level SimConn tests (real sockets, measured timing)
// ============================================================================

// newUDPPair creates two connected UDP sockets on localhost for testing.
func newUDPPair(t *testing.T) (*net.UDPConn, *net.UDPConn) {
	t.Helper()
	a, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	b, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		a.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { a.Close(); b.Close() })
	return a, b
}

func TestSimConnPassthrough(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(receiver)
	defer sim.Close()

	msg := []byte("hello passthrough")
	sender.WriteTo(msg, receiver.LocalAddr())

	buf := make([]byte, 1500)
	t0 := time.Now()
	n, _, err := sim.ReadFrom(buf)
	elapsed := time.Since(t0)

	if err != nil {
		t.Fatal(err)
	}
	if string(buf[:n]) != "hello passthrough" {
		t.Errorf("got %q", buf[:n])
	}
	if elapsed > 50*time.Millisecond {
		t.Errorf("passthrough took %v, expected <50ms", elapsed)
	}
}

func TestSimConnReadDelay(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(receiver)
	defer sim.Close()

	sim.SetProfile("starlink")

	msg := []byte("delayed packet")
	sender.WriteTo(msg, receiver.LocalAddr())

	buf := make([]byte, 1500)
	t0 := time.Now()
	n, _, err := sim.ReadFrom(buf)
	elapsed := time.Since(t0)

	if err != nil {
		t.Fatal(err)
	}
	if string(buf[:n]) != "delayed packet" {
		t.Errorf("got %q", buf[:n])
	}
	if elapsed < 50*time.Millisecond || elapsed > 500*time.Millisecond {
		t.Errorf("delay = %v, expected 50-500ms for starlink profile", elapsed)
	}
	t.Logf("ReadFrom delay: %v (starlink profile, 50ms base)", elapsed)
}

func TestSimConnWriteDelay(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(sender)
	defer sim.Close()

	sim.SetProfile("starlink")

	msg := []byte("delayed write")
	t0 := time.Now()
	sim.WriteTo(msg, receiver.LocalAddr())

	buf := make([]byte, 1500)
	receiver.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, _, err := receiver.ReadFrom(buf)
	elapsed := time.Since(t0)

	if err != nil {
		t.Fatal(err)
	}
	if string(buf[:n]) != "delayed write" {
		t.Errorf("got %q", buf[:n])
	}
	if elapsed < 50*time.Millisecond || elapsed > 500*time.Millisecond {
		t.Errorf("write delay = %v, expected 50-500ms for starlink profile", elapsed)
	}
	t.Logf("WriteTo→ReadFrom delay: %v (starlink profile, 50ms base)", elapsed)
}

func TestSimConnIndependentPerPacketDelay(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(receiver)
	defer sim.Close()

	sim.SetProfile(`{"name":"IndependentDelay","latencyMs":80,"jitterMeanMs":0,"jitterP99Ms":0,"packetLoss":0,"burstLen":0,"bandwidthBps":0}`)

	const numPackets = 5
	for i := 0; i < numPackets; i++ {
		sender.WriteTo([]byte(fmt.Sprintf("pkt-%d", i)), receiver.LocalAddr())
	}

	arrivals := make([]time.Duration, numPackets)
	t0 := time.Now()
	buf := make([]byte, 1500)
	sim.SetReadDeadline(time.Now().Add(2 * time.Second))
	for i := 0; i < numPackets; i++ {
		_, _, err := sim.ReadFrom(buf)
		if err != nil {
			t.Fatalf("packet %d read failed: %v", i, err)
		}
		arrivals[i] = time.Since(t0)
	}

	last := arrivals[numPackets-1]
	if last > 300*time.Millisecond {
		t.Errorf("last packet arrived at %v — looks like sequential blocking (expected <300ms)", last)
	}

	spread := arrivals[numPackets-1] - arrivals[0]
	t.Logf("Arrivals: %v (spread: %v)", arrivals, spread)

	if spread > 150*time.Millisecond {
		t.Errorf("spread = %v, expected <150ms (independent timers, not sequential)", spread)
	}
}

func TestSimConnPacketLoss(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(receiver)
	defer sim.Close()

	sim.SetProfile(`{"name":"LossTest","latencyMs":0,"jitterMeanMs":0,"jitterP99Ms":0,"packetLoss":0.10,"burstLen":0,"bandwidthBps":0}`)

	const total = 1000
	received := 0
	done := make(chan struct{})

	go func() {
		defer close(done)
		buf := make([]byte, 1500)
		for {
			sim.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
			_, _, err := sim.ReadFrom(buf)
			if err != nil {
				return
			}
			received++
		}
	}()

	for i := 0; i < total; i++ {
		sender.WriteTo([]byte("x"), receiver.LocalAddr())
		time.Sleep(100 * time.Microsecond)
	}

	time.Sleep(500 * time.Millisecond)
	sim.SetReadDeadline(time.Now())
	<-done

	dropRate := 1.0 - float64(received)/float64(total)
	t.Logf("Packet loss: sent=%d received=%d dropped=%.1f%% (expected ~10%%)", total, received, dropRate*100)

	if dropRate < 0.05 || dropRate > 0.20 {
		t.Errorf("drop rate = %.2f, expected in [0.05, 0.20] for 10%% loss", dropRate)
	}
}

func TestSimConnBandwidthLimit(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(sender)
	defer sim.Close()

	sim.SetProfile(`{"name":"BWTest","latencyMs":0,"jitterMeanMs":0,"jitterP99Ms":0,"packetLoss":0,"burstLen":0,"bandwidthBps":50000}`)

	const packetSize = 1000
	const numPackets = 100
	totalBytes := packetSize * numPackets

	var wg sync.WaitGroup
	wg.Add(1)
	var receivedBytes int
	go func() {
		defer wg.Done()
		buf := make([]byte, 2000)
		for {
			receiver.SetReadDeadline(time.Now().Add(3 * time.Second))
			n, _, err := receiver.ReadFrom(buf)
			if err != nil {
				return
			}
			receivedBytes += n
			if receivedBytes >= totalBytes {
				return
			}
		}
	}()

	t0 := time.Now()
	payload := make([]byte, packetSize)
	for i := 0; i < numPackets; i++ {
		sim.WriteTo(payload, receiver.LocalAddr())
	}
	wg.Wait()
	elapsed := time.Since(t0)

	measuredRate := float64(totalBytes) / elapsed.Seconds()
	t.Logf("Bandwidth: %d bytes in %v = %.0f B/s (limit=50000 B/s)", totalBytes, elapsed, measuredRate)

	if elapsed < 1*time.Second || elapsed > 4*time.Second {
		t.Errorf("elapsed = %v, expected 1-4s for 100KB at 50KB/s", elapsed)
	}
}

func TestSimConnConcurrentAccess(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(receiver)
	defer sim.Close()

	sim.SetProfile("starlink")

	var wg sync.WaitGroup

	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 100; i++ {
			sender.WriteTo([]byte("concurrent"), receiver.LocalAddr())
			time.Sleep(time.Millisecond)
		}
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		buf := make([]byte, 1500)
		for i := 0; i < 50; i++ {
			sim.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
			sim.ReadFrom(buf)
		}
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		profiles := []string{"none", "starlink", "jetblue", "turkish-air"}
		for i := 0; i < 20; i++ {
			sim.SetProfile(profiles[i%len(profiles)])
			time.Sleep(5 * time.Millisecond)
		}
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 20; i++ {
			_ = sim.Stats()
			_ = sim.IsActive()
			_ = sim.GetProfile()
			time.Sleep(5 * time.Millisecond)
		}
	}()

	wg.Wait()
	stats := sim.Stats()
	t.Logf("Concurrent test stats: read=%d written(to sender)=%d dropped=%d",
		stats.ReadPackets, stats.WritePackets, stats.ReadDropped)
}

func TestSimConnProfileSwitch(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(receiver)
	defer sim.Close()

	sim.SetProfile("starlink")

	sender.WriteTo([]byte("before"), receiver.LocalAddr())
	buf := make([]byte, 1500)
	t0 := time.Now()
	sim.ReadFrom(buf)
	delayBefore := time.Since(t0)

	sim.SetProfile("none")

	sender.WriteTo([]byte("after"), receiver.LocalAddr())
	t0 = time.Now()
	sim.ReadFrom(buf)
	delayAfter := time.Since(t0)

	t.Logf("Before (starlink): %v, After (none): %v", delayBefore, delayAfter)

	if delayBefore < 50*time.Millisecond {
		t.Errorf("expected delay with starlink profile, got %v", delayBefore)
	}
	if delayAfter > 50*time.Millisecond {
		t.Errorf("expected no delay with none profile, got %v", delayAfter)
	}
}

func TestSimConnCloseDuringInFlightPackets(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(receiver)

	sim.SetProfile(`{"name":"SlowClose","latencyMs":500,"jitterMeanMs":0,"jitterP99Ms":0,"packetLoss":0,"burstLen":0,"bandwidthBps":0}`)

	for i := 0; i < 50; i++ {
		sender.WriteTo([]byte(fmt.Sprintf("inflight-%d", i)), receiver.LocalAddr())
	}

	time.Sleep(50 * time.Millisecond)

	done := make(chan struct{})
	go func() {
		sim.Close()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("SimConn.Close() deadlocked with in-flight packets")
	}

	buf := make([]byte, 1500)
	_, _, err := sim.ReadFrom(buf)
	if err == nil {
		t.Error("expected error from ReadFrom after Close, got nil")
	}

	time.Sleep(600 * time.Millisecond)
	t.Log("close during in-flight packets: no panic, no deadlock")
}

func TestSimConnLifecycleConvergence(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(receiver)

	// Phase 1: passthrough
	sender.WriteTo([]byte("phase1"), receiver.LocalAddr())
	buf := make([]byte, 1500)
	t0 := time.Now()
	n, _, err := sim.ReadFrom(buf)
	if err != nil {
		t.Fatalf("phase 1 read: %v", err)
	}
	if string(buf[:n]) != "phase1" {
		t.Fatalf("phase 1: got %q", buf[:n])
	}
	if time.Since(t0) > 50*time.Millisecond {
		t.Errorf("phase 1: passthrough too slow: %v", time.Since(t0))
	}

	// Phase 2: activate moderate
	sim.SetProfile("starlink")
	sender.WriteTo([]byte("phase2"), receiver.LocalAddr())
	t0 = time.Now()
	n, _, err = sim.ReadFrom(buf)
	if err != nil {
		t.Fatalf("phase 2 read: %v", err)
	}
	if string(buf[:n]) != "phase2" {
		t.Fatalf("phase 2: got %q", buf[:n])
	}
	phase2Delay := time.Since(t0)
	if phase2Delay < 50*time.Millisecond {
		t.Errorf("phase 2: expected delay, got %v", phase2Delay)
	}

	// Phase 3: switch to none
	sim.SetProfile("none")
	sender.WriteTo([]byte("phase3"), receiver.LocalAddr())
	t0 = time.Now()
	n, _, err = sim.ReadFrom(buf)
	if err != nil {
		t.Fatalf("phase 3 read: %v", err)
	}
	if string(buf[:n]) != "phase3" {
		t.Fatalf("phase 3: got %q", buf[:n])
	}
	if time.Since(t0) > 50*time.Millisecond {
		t.Errorf("phase 3: expected instant after switching to none, got %v", time.Since(t0))
	}

	// Phase 4: close mid-flight
	sim.SetProfile(`{"name":"HighLat","latencyMs":500,"jitterMeanMs":0,"jitterP99Ms":0,"packetLoss":0,"burstLen":0,"bandwidthBps":0}`)
	for i := 0; i < 20; i++ {
		sender.WriteTo([]byte("phase4"), receiver.LocalAddr())
	}
	time.Sleep(30 * time.Millisecond)

	closeDone := make(chan struct{})
	go func() {
		sim.Close()
		close(closeDone)
	}()
	select {
	case <-closeDone:
	case <-time.After(2 * time.Second):
		t.Fatal("phase 4: Close deadlocked")
	}

	_, _, err = sim.ReadFrom(buf)
	if err == nil {
		t.Error("phase 4: expected error from ReadFrom after Close")
	}

	time.Sleep(600 * time.Millisecond)

	stats := sim.Stats()
	if stats.ReadPackets < 3 {
		t.Errorf("expected >= 3 read packets across lifecycle, got %d", stats.ReadPackets)
	}
	t.Logf("lifecycle: read=%d bytes=%d dropped=%d (phase2 delay=%v)",
		stats.ReadPackets, stats.ReadBytes, stats.ReadDropped, phase2Delay)
}

// ============================================================================
// Regression tests
// ============================================================================

func TestSetReadDeadlineDoesNotKillSimConn(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(receiver)
	defer sim.Close()

	sim.SetReadDeadline(time.Now().Add(50 * time.Millisecond))

	buf := make([]byte, 1500)
	_, _, err := sim.ReadFrom(buf)
	if err == nil {
		t.Fatal("expected timeout error from ReadFrom with deadline, got nil")
	}

	sim.SetReadDeadline(time.Time{})

	sender.WriteTo([]byte("still alive"), receiver.LocalAddr())
	n, _, err := sim.ReadFrom(buf)
	if err != nil {
		t.Fatalf("SimConn died after SetReadDeadline timeout: %v", err)
	}
	if string(buf[:n]) != "still alive" {
		t.Errorf("got %q, want %q", buf[:n], "still alive")
	}
}

func TestCloseUnblocksSlowBandwidthPacing(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(sender)

	sim.SetProfile(`{"name":"SlowBW","latencyMs":0,"jitterMeanMs":0,"jitterP99Ms":0,"packetLoss":0,"burstLen":0,"bandwidthBps":100}`)

	sim.WriteTo(make([]byte, 1400), receiver.LocalAddr())

	writeDone := make(chan struct{})
	go func() {
		sim.WriteTo(make([]byte, 1400), receiver.LocalAddr())
		close(writeDone)
	}()
	time.Sleep(100 * time.Millisecond)

	sim.Close()

	select {
	case <-writeDone:
	case <-time.After(2 * time.Second):
		t.Fatal("WriteTo still blocked after Close — sleep not interruptible")
	}
}

func TestBandwidthIsPerDirection(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(receiver)
	defer sim.Close()

	sim.SetProfile(`{"name":"BWDir","latencyMs":0,"jitterMeanMs":0,"jitterP99Ms":0,"packetLoss":0,"burstLen":0,"bandwidthBps":50000}`)

	const dataSize = 50000
	const pktSize = 1000
	const numPkts = dataSize / pktSize

	writeTarget, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer writeTarget.Close()

	var wg sync.WaitGroup
	var readDuration, writeDuration time.Duration

	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < numPkts; i++ {
			sender.WriteTo(make([]byte, pktSize), receiver.LocalAddr())
		}
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		buf := make([]byte, 2000)
		t0 := time.Now()
		for i := 0; i < numPkts; i++ {
			if _, _, err := sim.ReadFrom(buf); err != nil {
				break
			}
		}
		readDuration = time.Since(t0)
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		t0 := time.Now()
		payload := make([]byte, pktSize)
		for i := 0; i < numPkts; i++ {
			sim.WriteTo(payload, writeTarget.LocalAddr())
		}
		writeDuration = time.Since(t0)
	}()

	wg.Wait()

	readRate := float64(dataSize) / readDuration.Seconds()
	writeRate := float64(dataSize) / writeDuration.Seconds()
	t.Logf("Read: %v (%.0f B/s), Write: %v (%.0f B/s), limit=50000 B/s per dir",
		readDuration, readRate, writeDuration, writeRate)

	minRate := 50000.0 * 0.70
	if readRate < minRate {
		t.Errorf("read rate %.0f B/s < %.0f B/s — bandwidth may be shared", readRate, minRate)
	}
	if writeRate < minRate {
		t.Errorf("write rate %.0f B/s < %.0f B/s — bandwidth may be shared", writeRate, minRate)
	}
}

func TestBufferOverflowTrackedSeparately(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(receiver)

	sim.SetProfile(`{"name":"Overflow","latencyMs":500,"jitterMeanMs":0,"jitterP99Ms":0,"packetLoss":0,"burstLen":0,"bandwidthBps":0}`)

	for i := 0; i < 3000; i++ {
		sender.WriteTo([]byte("x"), receiver.LocalAddr())
		time.Sleep(10 * time.Microsecond)
	}

	time.Sleep(700 * time.Millisecond)

	stats := sim.Stats()
	t.Logf("Overflow: readPackets=%d readDropped=%d readOverflow=%d",
		stats.ReadPackets, stats.ReadDropped, stats.ReadOverflow)

	if stats.ReadDropped != 0 {
		t.Errorf("ReadDropped = %d, want 0 (no configured loss)", stats.ReadDropped)
	}
	if stats.ReadOverflow == 0 {
		t.Error("ReadOverflow = 0, expected > 0")
	}
	sim.Close()
}

func TestSetProfileReturnsFalseForInvalidID(t *testing.T) {
	_, receiver := newUDPPair(t)
	sim := Wrap(receiver)
	defer sim.Close()

	if ok := sim.SetProfile("nonexistent"); ok {
		t.Error("SetProfile(\"nonexistent\") returned true, expected false")
	}
	if ok := sim.SetProfile("starlink"); !ok {
		t.Error("SetProfile(\"moderate\") returned false, expected true")
	}
	if ok := sim.SetProfile("{invalid json"); ok {
		t.Error("SetProfile(\"{invalid json\") returned true, expected false")
	}
	p := sim.GetProfile()
	if p.LatencyMs != 50 {
		t.Errorf("profile latency=%d after bad SetProfile, want 50 (starlink)", p.LatencyMs)
	}
}

func TestWriteToAfterFuncRespectsClose(t *testing.T) {
	sender, receiver := newUDPPair(t)
	sim := Wrap(sender)

	sim.SetProfile(`{"name":"DelayW","latencyMs":500,"jitterMeanMs":0,"jitterP99Ms":0,"packetLoss":0,"burstLen":0,"bandwidthBps":0}`)

	for i := 0; i < 50; i++ {
		sim.WriteTo([]byte("x"), receiver.LocalAddr())
	}

	time.Sleep(50 * time.Millisecond)
	sim.Close()

	time.Sleep(600 * time.Millisecond)

	received := 0
	buf := make([]byte, 64)
	for {
		receiver.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
		_, _, err := receiver.ReadFrom(buf)
		if err != nil {
			break
		}
		received++
	}

	t.Logf("packets received after close: %d (expected 0)", received)
	if received > 0 {
		t.Errorf("%d packets arrived after Close — AfterFunc should check closeCh", received)
	}
}
