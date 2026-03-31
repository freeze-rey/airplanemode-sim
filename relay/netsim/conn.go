package netsim

import (
	"context"
	"fmt"
	"math/rand"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/net/ipv4"
	"golang.org/x/time/rate"
)

const oobBufferSize = 128

// rateBurst is the token-bucket burst size for bandwidth limiting. Set to the
// standard Ethernet MTU. This is safe because SimConn only wraps the QUIC
// listener socket, and QUIC datagrams are ≤1200 bytes (RFC 9000 §14.1).
// If SimConn is ever used for non-QUIC traffic, this must be raised.
const rateBurst = 1500

func (c *SimConn) shutdown() {
	c.closeOnce.Do(func() { close(c.closeCh) })
}

// delayedPacket is a packet buffered for delayed delivery, carrying OOB data
// so quic-go can read ECN bits and packet info through SimConn.
type delayedPacket struct {
	data  []byte
	oob   []byte
	oobn  int
	flags int
	addr  *net.UDPAddr
}

// SimConn wraps a *net.UDPConn with network simulation at the UDP packet level.
//
// It implements:
//   - net.PacketConn (ReadFrom/WriteTo — used by unit tests)
//   - quic-go's OOBCapablePacketConn (ReadMsgUDP/WriteMsgUDP/SyscallConn/SetReadBuffer)
//   - quic-go's batchConn (ReadBatch) — prevents quic-go from bypassing SimConn
//     via ipv4.NewPacketConn raw fd reads
//
// At runtime, quic-go calls ReadBatch (not ReadMsgUDP) for reads and WriteMsgUDP
// for writes. ReadMsgUDP satisfies the OOBCapablePacketConn type assertion but is
// not called by quic-go's oobConn.
type SimConn struct {
	inner *net.UDPConn

	mu                  sync.Mutex
	profile             NetworkProfile
	readBurstRemaining  int
	writeBurstRemaining int
	readLimiter         *rate.Limiter
	writeLimiter        *rate.Limiter

	ctx       context.Context
	cancel    context.CancelFunc
	readyCh   chan delayedPacket
	closeCh   chan struct{}
	closeOnce sync.Once

	deadlineMu    sync.Mutex
	deadlineCh    chan struct{}
	deadlineTimer *time.Timer

	readPackets  atomic.Int64
	readBytes    atomic.Int64
	readDropped  atomic.Int64
	readOverflow atomic.Int64
	writePackets atomic.Int64
	writeBytes   atomic.Int64
	writeDropped atomic.Int64

	delays delayStats // Welford's online mean + stddev of conditioning delays
}

// Wrap creates a SimConn around an existing *net.UDPConn.
// Starts with the "none" profile (passthrough).
func Wrap(inner *net.UDPConn) *SimConn {
	ctx, cancel := context.WithCancel(context.Background())
	c := &SimConn{
		inner:      inner,
		profile:    Profiles["none"],
		ctx:        ctx,
		cancel:     cancel,
		readyCh:    make(chan delayedPacket, 2048),
		closeCh:    make(chan struct{}),
		deadlineCh: make(chan struct{}),
	}
	go c.readLoop()
	return c
}

// SetProfile switches the active network profile.
// Accepts a preset name ("turkish-air") or JSON string.
// Returns false if the profile ID is unrecognized.
// Thread-safe; takes effect on the next packet.
func (c *SimConn) SetProfile(id string) bool {
	p, ok := ResolveProfile(id)
	if !ok {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.profile = p
	c.readBurstRemaining = 0
	c.writeBurstRemaining = 0
	if p.BandwidthBps > 0 {
		c.readLimiter = rate.NewLimiter(rate.Limit(p.BandwidthBps), rateBurst)
		c.writeLimiter = rate.NewLimiter(rate.Limit(p.BandwidthBps), rateBurst)
	} else {
		c.readLimiter = nil
		c.writeLimiter = nil
	}
	return true
}

// GetProfile returns a snapshot of the active profile.
func (c *SimConn) GetProfile() NetworkProfile {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.profile
}

// IsActive returns true if any simulation is applied.
func (c *SimConn) IsActive() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return !c.profile.IsPassthrough()
}

// Stats returns a snapshot of accumulated statistics.
func (c *SimConn) Stats() Stats {
	return Stats{
		ReadPackets:  c.readPackets.Load(),
		ReadBytes:    c.readBytes.Load(),
		ReadDropped:  c.readDropped.Load(),
		ReadOverflow: c.readOverflow.Load(),
		WritePackets: c.writePackets.Load(),
		WriteBytes:   c.writeBytes.Load(),
		WriteDropped: c.writeDropped.Load(),
	}
}

// DelaySnapshot returns the mean and stddev of conditioning delays since the
// last call, then resets for the next interval. Uses Welford's algorithm.
func (c *SimConn) DelaySnapshot() (count int64, meanNanos float64, stddevNanos float64) {
	return c.delays.snapshot()
}

// ResetStats atomically resets all counters to zero.
func (c *SimConn) ResetStats() {
	c.readPackets.Store(0)
	c.readBytes.Store(0)
	c.readDropped.Store(0)
	c.readOverflow.Store(0)
	c.writePackets.Store(0)
	c.writeBytes.Store(0)
	c.writeDropped.Store(0)
	c.delays.snapshot() // reset delay stats
}

// ---- OOBCapablePacketConn (quic-go type assertion) ----

// ReadMsgUDP satisfies quic-go's OOBCapablePacketConn interface. quic-go does not
// call this at runtime (it uses ReadBatch instead), but the type assertion in
// wrapConn() requires it. Also usable as a direct test API.
func (c *SimConn) ReadMsgUDP(b, oob []byte) (n, oobn, flags int, addr *net.UDPAddr, err error) {
	select {
	case dp, ok := <-c.readyCh:
		if !ok {
			return 0, 0, 0, nil, net.ErrClosed
		}
		n = copy(b, dp.data)
		oobn = copy(oob, dp.oob)
		return n, oobn, dp.flags, dp.addr, nil
	case <-c.closeCh:
		return 0, 0, 0, nil, net.ErrClosed
	}
}

// WriteMsgUDP sends a packet through the simulation (delay + loss + bandwidth),
// preserving OOB data (ECN/GSO). Delayed OOB is safe: outgoing OOB carries ECN
// ECT bits (static capability, not congestion feedback) and GSO size (applied at
// kernel send time).
func (c *SimConn) WriteMsgUDP(b, oob []byte, addr *net.UDPAddr) (n, oobn int, err error) {
	entryTime := time.Now()

	c.mu.Lock()
	profile := c.profile
	lim := c.writeLimiter
	c.mu.Unlock()

	n = len(b)

	if c.shouldDrop(false) {
		c.writeDropped.Add(1)
		return n, len(oob), nil
	}

	if lim != nil {
		res := lim.ReserveN(time.Now(), n)
		if res.OK() {
			if wait := res.Delay(); wait > 0 {
				select {
				case <-time.After(wait):
				case <-c.closeCh:
					return n, len(oob), nil
				}
			}
		}
	}

	c.writePackets.Add(1)
	c.writeBytes.Add(int64(n))

	delay := profile.ComputeDelay()
	// Record total conditioning: bandwidth wait + jitter delay (synchronous)
	c.delays.record(time.Since(entryTime) + delay)
	if delay == 0 {
		return c.inner.WriteMsgUDP(b, oob, addr)
	}

	bCopy := make([]byte, n)
	copy(bCopy, b)
	oobCopy := make([]byte, len(oob))
	copy(oobCopy, oob)
	time.AfterFunc(delay, func() {
		select {
		case <-c.closeCh:
			return
		default:
			c.inner.WriteMsgUDP(bCopy, oobCopy, addr)
		}
	})
	return n, len(oob), nil
}

func (c *SimConn) SyscallConn() (syscall.RawConn, error) {
	return c.inner.SyscallConn()
}

func (c *SimConn) SetReadBuffer(bytes int) error {
	return c.inner.SetReadBuffer(bytes)
}

func (c *SimConn) SetWriteBuffer(bytes int) error {
	return c.inner.SetWriteBuffer(bytes)
}

// ---- batchConn (prevents quic-go from bypassing SimConn via raw fd) ----

// ReadBatch is the hot read path called by quic-go's oobConn.ReadPacket().
// It reads simulated packets from readyCh and fills pre-allocated ipv4.Message
// structs. The first message blocks; subsequent messages drain non-blocking.
func (c *SimConn) ReadBatch(ms []ipv4.Message, flags int) (int, error) {
	if len(ms) == 0 {
		return 0, nil
	}

	dp, ok := c.readFirst()
	if !ok {
		return 0, net.ErrClosed
	}
	fillMessage(&ms[0], dp)
	filled := 1

	for filled < len(ms) {
		select {
		case dp, ok := <-c.readyCh:
			if !ok {
				return filled, nil
			}
			fillMessage(&ms[filled], dp)
			filled++
		default:
			return filled, nil
		}
	}
	return filled, nil
}

func (c *SimConn) readFirst() (delayedPacket, bool) {
	select {
	case dp, ok := <-c.readyCh:
		return dp, ok
	case <-c.closeCh:
		return delayedPacket{}, false
	}
}

// fillMessage copies a delayedPacket into a pre-allocated ipv4.Message.
// quic-go pre-allocates Buffers[0] and OOB via its buffer pool; we must copy
// into the existing slices rather than replacing them.
func fillMessage(msg *ipv4.Message, dp delayedPacket) {
	if len(msg.Buffers) > 0 && len(msg.Buffers[0]) >= len(dp.data) {
		n := copy(msg.Buffers[0], dp.data)
		msg.N = n
	} else {
		msg.Buffers = [][]byte{dp.data}
		msg.N = len(dp.data)
	}
	if len(msg.OOB) >= dp.oobn {
		copy(msg.OOB, dp.oob)
		msg.NN = dp.oobn
	} else {
		msg.OOB = dp.oob
		msg.NN = dp.oobn
	}
	msg.Addr = dp.addr
}

// ---- net.PacketConn interface (backward compat for unit tests) ----

// ReadFrom returns the next delayed inbound packet. Blocks until one is ready,
// the read deadline fires, or the SimConn is closed.
func (c *SimConn) ReadFrom(p []byte) (int, net.Addr, error) {
	for {
		c.deadlineMu.Lock()
		dlCh := c.deadlineCh
		c.deadlineMu.Unlock()

		select {
		case dp, ok := <-c.readyCh:
			if !ok {
				return 0, nil, net.ErrClosed
			}
			n := copy(p, dp.data)
			return n, dp.addr, nil
		case <-dlCh:
			c.deadlineMu.Lock()
			same := c.deadlineCh == dlCh
			c.deadlineMu.Unlock()
			if same {
				return 0, nil, os.ErrDeadlineExceeded
			}
			continue
		case <-c.closeCh:
			return 0, nil, net.ErrClosed
		}
	}
}

// WriteTo sends a packet through the simulation (delay + loss + bandwidth).
func (c *SimConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	entryTime := time.Now()

	c.mu.Lock()
	profile := c.profile
	lim := c.writeLimiter
	c.mu.Unlock()

	n := len(p)

	if c.shouldDrop(false) {
		c.writeDropped.Add(1)
		return n, nil
	}

	if lim != nil {
		res := lim.ReserveN(time.Now(), n)
		if res.OK() {
			if wait := res.Delay(); wait > 0 {
				select {
				case <-time.After(wait):
				case <-c.closeCh:
					return n, nil
				}
			}
		}
	}

	c.writePackets.Add(1)
	c.writeBytes.Add(int64(n))

	delay := profile.ComputeDelay()
	c.delays.record(time.Since(entryTime) + delay)
	if delay == 0 {
		return c.inner.WriteTo(p, addr)
	}

	pktCopy := make([]byte, n)
	copy(pktCopy, p)
	time.AfterFunc(delay, func() {
		select {
		case <-c.closeCh:
			return
		default:
			c.inner.WriteTo(pktCopy, addr)
		}
	})
	return n, nil
}

func (c *SimConn) LocalAddr() net.Addr { return c.inner.LocalAddr() }

func (c *SimConn) SetDeadline(t time.Time) error {
	if err := c.SetReadDeadline(t); err != nil {
		return err
	}
	return c.inner.SetWriteDeadline(t)
}

// SetReadDeadline sets a deadline for ReadFrom. After the deadline,
// ReadFrom returns os.ErrDeadlineExceeded. A zero value clears the deadline.
// Does not affect the inner conn's read deadline (readLoop manages that).
func (c *SimConn) SetReadDeadline(t time.Time) error {
	c.deadlineMu.Lock()
	defer c.deadlineMu.Unlock()

	if c.deadlineTimer != nil {
		c.deadlineTimer.Stop()
		c.deadlineTimer = nil
	}

	select {
	case <-c.deadlineCh:
	default:
		close(c.deadlineCh)
	}
	c.deadlineCh = make(chan struct{})

	if t.IsZero() {
		return nil
	}

	d := time.Until(t)
	if d <= 0 {
		close(c.deadlineCh)
		return nil
	}

	ch := c.deadlineCh
	c.deadlineTimer = time.AfterFunc(d, func() {
		c.deadlineMu.Lock()
		defer c.deadlineMu.Unlock()
		if c.deadlineCh == ch {
			close(ch)
		}
	})
	return nil
}

func (c *SimConn) SetWriteDeadline(t time.Time) error { return c.inner.SetWriteDeadline(t) }

// Close stops the read loop and closes the inner connection.
func (c *SimConn) Close() error {
	c.shutdown()
	c.cancel()
	return c.inner.Close()
}

// ---- internal ----

// readLoop reads packets from the inner conn via ReadMsgUDP (preserving OOB
// data for ECN/packet info) and schedules them for delayed delivery via readyCh.
func (c *SimConn) readLoop() {
	buf := make([]byte, 65536)
	oobBuf := make([]byte, oobBufferSize)
	for {
		n, oobn, flags, addr, err := c.inner.ReadMsgUDP(buf, oobBuf)
		if err != nil {
			c.shutdown()
			return
		}

		arrivedAt := time.Now()

		if c.shouldDrop(true) {
			c.readDropped.Add(1)
			continue
		}

		c.mu.Lock()
		profile := c.profile
		lim := c.readLimiter
		c.mu.Unlock()

		if lim != nil {
			if n > rateBurst {
				// Invariant violation: SimConn wraps a QUIC listener, so packets
				// should never exceed rateBurst (1500). If this fires, SimConn is
				// being used for non-QUIC traffic and rateBurst must be raised.
				panic(fmt.Sprintf("netsim: packet size %d exceeds rate burst %d — SimConn is QUIC-only", n, rateBurst))
			}
			if err := lim.WaitN(c.ctx, n); err != nil {
				return
			}
		}

		c.readPackets.Add(1)
		c.readBytes.Add(int64(n))

		pkt := make([]byte, n)
		copy(pkt, buf[:n])
		oob := make([]byte, oobn)
		copy(oob, oobBuf[:oobn])
		dp := delayedPacket{data: pkt, oob: oob, oobn: oobn, flags: flags, addr: addr}

		delay := profile.ComputeDelay()
		// Record total conditioning: bandwidth wait + jitter delay (synchronous)
		c.delays.record(time.Since(arrivedAt) + delay)
		if delay == 0 {
			select {
			case c.readyCh <- dp:
			case <-c.closeCh:
				return
			}
		} else {
			time.AfterFunc(delay, func() {
				select {
				case c.readyCh <- dp:
				case <-c.closeCh:
				default:
					c.readOverflow.Add(1)
				}
			})
		}
	}
}

func (c *SimConn) shouldDrop(forRead bool) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	burst := &c.writeBurstRemaining
	if forRead {
		burst = &c.readBurstRemaining
	}
	if *burst > 0 {
		*burst--
		return true
	}
	if c.profile.PacketLoss <= 0 {
		return false
	}
	if rand.Float64() < c.profile.PacketLoss {
		*burst = c.profile.BurstLen
		return true
	}
	return false
}
