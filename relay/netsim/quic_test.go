package netsim

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"fmt"
	"math"
	"math/big"
	"net"
	"sort"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/quic-go/quic-go"
	"golang.org/x/net/ipv4"
)

// ============================================================================
// QUIC integration tests — prove SimConn works with real QUIC features
// ============================================================================

func generateSelfSignedCert() tls.Certificate {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		NotBefore:    time.Now(),
		NotAfter:     time.Now().Add(24 * time.Hour),
		IPAddresses:  []net.IP{net.IPv4(127, 0, 0, 1)},
	}
	certDER, _ := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	return tls.Certificate{
		Certificate: [][]byte{certDER},
		PrivateKey:  key,
	}
}

type countingReadPathSimConn struct {
	*SimConn
	readBatchCalls  atomic.Int64
	readMsgUDPCalls atomic.Int64
}

func (c *countingReadPathSimConn) ReadBatch(ms []ipv4.Message, flags int) (int, error) {
	c.readBatchCalls.Add(1)
	return c.SimConn.ReadBatch(ms, flags)
}

func (c *countingReadPathSimConn) ReadMsgUDP(b, oob []byte) (n, oobn, flags int, addr *net.UDPAddr, err error) {
	c.readMsgUDPCalls.Add(1)
	return c.SimConn.ReadMsgUDP(b, oob)
}

func quicPair(t *testing.T, profileID string) (clientConn *quic.Conn, serverConn *quic.Conn, sim *SimConn) {
	t.Helper()

	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}

	sim = Wrap(udpConn)
	if profileID != "" {
		sim.SetProfile(profileID)
	}

	cert := generateSelfSignedCert()
	serverTLS := &tls.Config{
		Certificates: []tls.Certificate{cert},
		NextProtos:   []string{"netsim-test"},
	}
	clientTLS := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"netsim-test"},
	}

	tr := &quic.Transport{Conn: sim}
	listener, err := tr.Listen(serverTLS, &quic.Config{
		EnableDatagrams: true,
	})
	if err != nil {
		sim.Close()
		t.Fatal(err)
	}

	serverReady := make(chan *quic.Conn, 1)
	go func() {
		conn, err := listener.Accept(context.Background())
		if err != nil {
			return
		}
		serverReady <- conn
	}()

	clientConn, err = quic.DialAddr(
		context.Background(),
		sim.LocalAddr().String(),
		clientTLS,
		&quic.Config{EnableDatagrams: true},
	)
	if err != nil {
		sim.Close()
		t.Fatal(err)
	}

	select {
	case serverConn = <-serverReady:
	case <-time.After(5 * time.Second):
		sim.Close()
		t.Fatal("timeout waiting for server connection")
	}

	t.Cleanup(func() {
		clientConn.CloseWithError(0, "test done")
		serverConn.CloseWithError(0, "test done")
		listener.Close()
		sim.Close()
	})

	return clientConn, serverConn, sim
}

func TestQUICUsesReadBatchOnSimConn(t *testing.T) {
	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}

	baseSim := Wrap(udpConn)
	sim := &countingReadPathSimConn{SimConn: baseSim}

	cert := generateSelfSignedCert()
	serverTLS := &tls.Config{
		Certificates: []tls.Certificate{cert},
		NextProtos:   []string{"netsim-test"},
	}
	clientTLS := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"netsim-test"},
	}

	tr := &quic.Transport{Conn: sim}
	listener, err := tr.Listen(serverTLS, &quic.Config{EnableDatagrams: true})
	if err != nil {
		sim.Close()
		t.Fatal(err)
	}

	serverReady := make(chan *quic.Conn, 1)
	go func() {
		conn, err := listener.Accept(context.Background())
		if err != nil {
			return
		}
		serverReady <- conn
	}()

	clientConn, err := quic.DialAddr(
		context.Background(),
		sim.LocalAddr().String(),
		clientTLS,
		&quic.Config{EnableDatagrams: true},
	)
	if err != nil {
		listener.Close()
		sim.Close()
		t.Fatal(err)
	}

	var serverConn *quic.Conn
	select {
	case serverConn = <-serverReady:
	case <-time.After(5 * time.Second):
		clientConn.CloseWithError(0, "timeout")
		listener.Close()
		sim.Close()
		t.Fatal("timeout waiting for server connection")
	}

	t.Cleanup(func() {
		clientConn.CloseWithError(0, "test done")
		serverConn.CloseWithError(0, "test done")
		listener.Close()
		sim.Close()
	})

	go func() {
		stream, err := serverConn.AcceptStream(context.Background())
		if err != nil {
			return
		}
		buf := make([]byte, 1024)
		n, _ := stream.Read(buf)
		stream.Write(buf[:n])
	}()

	stream, err := clientConn.OpenStreamSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if _, err := stream.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}

	buf := make([]byte, 1024)
	n, err := stream.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	if string(buf[:n]) != "ping" {
		t.Fatalf("got %q, want %q", buf[:n], "ping")
	}

	if sim.readBatchCalls.Load() == 0 {
		t.Fatal("expected quic-go to use ReadBatch on SimConn")
	}
	if calls := sim.readMsgUDPCalls.Load(); calls != 0 {
		t.Fatalf("expected quic-go to avoid ReadMsgUDP when ReadBatch is available, got %d calls", calls)
	}
}

func TestQUICStreamLatency(t *testing.T) {
	client, server, _ := quicPair(t, "starlink")

	go func() {
		stream, err := server.AcceptStream(context.Background())
		if err != nil {
			return
		}
		buf := make([]byte, 1024)
		n, _ := stream.Read(buf)
		stream.Write(buf[:n])
	}()

	stream, err := client.OpenStreamSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	msg := []byte("ping")
	t0 := time.Now()
	stream.Write(msg)

	buf := make([]byte, 1024)
	n, err := stream.Read(buf)
	rtt := time.Since(t0)

	if err != nil {
		t.Fatal(err)
	}
	if string(buf[:n]) != "ping" {
		t.Errorf("got %q, want %q", buf[:n], "ping")
	}

	t.Logf("QUIC stream RTT: %v (starlink profile, 50ms one-way)", rtt)
	if rtt < 100*time.Millisecond {
		t.Errorf("RTT %v too low — netsim not applying delay to QUIC", rtt)
	}
}

func TestQUICMultipleStreams(t *testing.T) {
	client, server, _ := quicPair(t, "starlink")

	const numStreams = 3

	go func() {
		for i := 0; i < numStreams; i++ {
			stream, err := server.AcceptStream(context.Background())
			if err != nil {
				return
			}
			go func() {
				buf := make([]byte, 1024)
				n, _ := stream.Read(buf)
				stream.Write(buf[:n])
			}()
		}
	}()

	var wg sync.WaitGroup
	rtts := make([]time.Duration, numStreams)

	for i := 0; i < numStreams; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			stream, err := client.OpenStreamSync(context.Background())
			if err != nil {
				t.Errorf("stream %d: open failed: %v", idx, err)
				return
			}
			msg := []byte(fmt.Sprintf("stream-%d", idx))
			t0 := time.Now()
			stream.Write(msg)
			buf := make([]byte, 1024)
			stream.Read(buf)
			rtts[idx] = time.Since(t0)
		}(i)
	}
	wg.Wait()

	t.Logf("Multi-stream RTTs: %v", rtts)

	for i, rtt := range rtts {
		if rtt < 100*time.Millisecond {
			t.Errorf("stream %d RTT %v too low", i, rtt)
		}
		if rtt > 2*time.Second {
			t.Errorf("stream %d RTT %v too high", i, rtt)
		}
	}

	sort.Slice(rtts, func(i, j int) bool { return rtts[i] < rtts[j] })
	spread := rtts[numStreams-1] - rtts[0]
	t.Logf("Stream RTT spread: %v", spread)
	if spread > 500*time.Millisecond {
		t.Errorf("stream RTT spread %v too high — streams may be serialized", spread)
	}
}

func TestQUICDatagramLoss(t *testing.T) {
	client, server, _ := quicPair(t, `{"name":"LossTest","latencyMs":5,"jitterMeanMs":0,"jitterP99Ms":0,"packetLoss":0.15,"burstLen":0,"bandwidthBps":0}`)

	const total = 200
	received := make(chan []byte, total)

	go func() {
		for {
			msg, err := server.ReceiveDatagram(context.Background())
			if err != nil {
				return
			}
			received <- msg
		}
	}()

	for i := 0; i < total; i++ {
		buf := make([]byte, 4)
		binary.BigEndian.PutUint32(buf, uint32(i))
		err := client.SendDatagram(buf)
		if err != nil {
			t.Logf("SendDatagram %d failed: %v", i, err)
		}
		time.Sleep(time.Millisecond)
	}

	time.Sleep(500 * time.Millisecond)

	count := len(received)
	dropRate := 1.0 - float64(count)/float64(total)
	t.Logf("Datagrams: sent=%d received=%d loss=%.1f%% (configured=15%%)", total, count, dropRate*100)

	if dropRate < 0.03 {
		t.Errorf("drop rate %.1f%% too low — datagrams should be lossy", dropRate*100)
	}
}

func TestQUICStreamReliableUnderLoss(t *testing.T) {
	client, server, _ := quicPair(t, `{"name":"LossTest","latencyMs":5,"jitterMeanMs":0,"jitterP99Ms":0,"packetLoss":0.10,"burstLen":0,"bandwidthBps":0}`)

	const dataSize = 10000

	serverDone := make(chan []byte, 1)
	go func() {
		stream, err := server.AcceptStream(context.Background())
		if err != nil {
			return
		}
		var data []byte
		buf := make([]byte, 4096)
		for {
			n, err := stream.Read(buf)
			if n > 0 {
				data = append(data, buf[:n]...)
			}
			if err != nil || len(data) >= dataSize {
				break
			}
		}
		serverDone <- data
	}()

	stream, err := client.OpenStreamSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	payload := make([]byte, dataSize)
	for i := range payload {
		payload[i] = byte(i % 256)
	}
	stream.Write(payload)
	stream.Close()

	select {
	case data := <-serverDone:
		t.Logf("Stream data: sent=%d received=%d (under 10%% packet loss)", dataSize, len(data))
		if len(data) != dataSize {
			t.Errorf("received %d bytes, want %d — QUIC retransmission may have failed", len(data), dataSize)
		}
		for i := range data {
			if data[i] != byte(i%256) {
				t.Fatalf("data corruption at byte %d: got %d want %d", i, data[i], byte(i%256))
			}
		}
		t.Log("Stream data integrity verified — QUIC retransmission works through SimConn")
	case <-time.After(10 * time.Second):
		t.Fatal("timeout waiting for stream data — QUIC may be stuck under packet loss")
	}
}

func TestQUICClientObservedRTTShape(t *testing.T) {
	client, server, _ := quicPair(t, `{"name":"LatencyDistTest","latencyMs":50,"jitterMeanMs":15,"jitterP99Ms":80,"packetLoss":0,"burstLen":0,"bandwidthBps":0}`)

	profile := NetworkProfile{
		Name: "LatencyDistTest", LatencyMs: 50, JitterMeanMs: 15, JitterP99Ms: 80,
	}

	go func() {
		stream, err := server.AcceptStream(context.Background())
		if err != nil {
			return
		}
		buf := make([]byte, 1024)
		for {
			n, err := stream.Read(buf)
			if err != nil {
				return
			}
			stream.Write(buf[:n])
		}
	}()

	stream, err := client.OpenStreamSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	const n = 500
	rtts := make([]float64, n)
	msg := []byte("ping")
	buf := make([]byte, 1024)

	for i := 0; i < n; i++ {
		t0 := time.Now()
		stream.Write(msg)
		stream.Read(buf)
		rtts[i] = float64(time.Since(t0).Milliseconds())
	}

	sort.Float64s(rtts)
	var sum float64
	for _, r := range rtts {
		sum += r
	}
	median := rtts[n/2]
	p99 := rtts[int(float64(n)*0.99)]
	mean := sum / float64(n)

	t.Logf("Client-observed RTT distribution (n=%d):", n)
	t.Logf("  median=%.0fms  mean=%.0fms  p99=%.0fms  min=%.0fms  max=%.0fms",
		median, mean, p99, rtts[0], rtts[n-1])

	const refN = 100_000
	refRTTs := make([]float64, refN)
	for i := 0; i < refN; i++ {
		refRTTs[i] = float64((profile.ComputeDelay() + profile.ComputeDelay()).Milliseconds())
	}
	sort.Float64s(refRTTs)

	quantiles := []float64{0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99}
	t.Logf("\n%-10s %10s %10s %10s", "Quantile", "Observed", "Theory", "Error%")
	maxError := 0.0
	for _, q := range quantiles {
		obsIdx := int(float64(n) * q)
		if obsIdx >= n {
			obsIdx = n - 1
		}
		refIdx := int(float64(refN) * q)
		if refIdx >= refN {
			refIdx = refN - 1
		}
		observed := rtts[obsIdx]
		theoretical := refRTTs[refIdx]
		errPct := 0.0
		if theoretical > 0 {
			errPct = math.Abs(observed-theoretical) / theoretical * 100
		}
		if errPct > maxError {
			maxError = errPct
		}
		t.Logf("P%-9.0f %8.0fms %8.0fms %9.1f%%", q*100, observed, theoretical, errPct)
	}

	if maxError > 15.0 {
		t.Errorf("max quantile error = %.1f%%, expected < 15%% — client may not see correct distribution", maxError)
	}

	if median < 70 || median > 160 {
		t.Errorf("median RTT = %.0fms, expected 70-160ms (2×50ms base)", median)
	}
	if p99 < 150 {
		t.Errorf("p99 RTT = %.0fms, expected >150ms (should show jitter tail)", p99)
	}
}

func TestQUICClientObservedBandwidth(t *testing.T) {
	client, server, _ := quicPair(t, `{"name":"BWTest","latencyMs":5,"jitterMeanMs":0,"jitterP99Ms":0,"packetLoss":0,"burstLen":0,"bandwidthBps":100000}`)

	const totalBytes = 200_000

	go func() {
		stream, err := server.AcceptStream(context.Background())
		if err != nil {
			return
		}
		buf := make([]byte, 8)
		stream.Read(buf)
		payload := make([]byte, 4096)
		sent := 0
		for sent < totalBytes {
			chunk := totalBytes - sent
			if chunk > len(payload) {
				chunk = len(payload)
			}
			n, err := stream.Write(payload[:chunk])
			if err != nil {
				return
			}
			sent += n
		}
		stream.Close()
	}()

	stream, err := client.OpenStreamSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	stream.Write([]byte("go"))

	t0 := time.Now()
	buf := make([]byte, 8192)
	received := 0
	for received < totalBytes {
		n, err := stream.Read(buf)
		if err != nil {
			break
		}
		received += n
	}
	elapsed := time.Since(t0)

	measuredRate := float64(received) / elapsed.Seconds()
	t.Logf("Client-observed bandwidth: %d bytes in %v = %.0f B/s (limit=100,000 B/s)",
		received, elapsed, measuredRate)

	if elapsed < 1*time.Second || elapsed > 5*time.Second {
		t.Errorf("elapsed = %v, expected 1-5s for 200KB at 100KB/s", elapsed)
	}

	if measuredRate > 150_000 {
		t.Errorf("measured rate = %.0f B/s, exceeds 1.5x configured limit — bandwidth not applied", measuredRate)
	}
}

func TestQUICUpstreamDelay(t *testing.T) {
	client, server, _ := quicPair(t, "starlink")

	go func() {
		stream, err := server.AcceptStream(context.Background())
		if err != nil {
			return
		}
		buf := make([]byte, 8)
		stream.Read(buf)
		stream.Write(buf)
	}()

	stream, err := client.OpenStreamSync(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	t0 := time.Now()
	ts := make([]byte, 8)
	binary.BigEndian.PutUint64(ts, uint64(t0.UnixNano()))
	stream.Write(ts)

	buf := make([]byte, 8)
	stream.Read(buf)
	rtt := time.Since(t0)

	t.Logf("Upstream RTT: %v (starlink profile, 50ms one-way each direction)", rtt)

	if rtt < 100*time.Millisecond {
		t.Errorf("upstream RTT %v too low — SimConn may not be delaying inbound packets", rtt)
	}
}
