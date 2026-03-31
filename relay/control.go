package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/freeze-rey/airplanemode-sim/relay/netsim"
)

// ControlServer exposes an HTTP/1.1 control API for the network simulator.
// Runs on localhost:4434 alongside the MASQUE relay.
type ControlServer struct {
	simConn *netsim.SimConn
	server  *http.Server

	mu        sync.Mutex
	lastStats netsim.Stats
	lastPoll  time.Time
}

// NewControlServer creates a control server backed by the given SimConn.
func NewControlServer(simConn *netsim.SimConn) *ControlServer {
	return &ControlServer{
		simConn:  simConn,
		lastPoll: time.Now(),
	}
}

// profileRequest is the JSON body for POST /profile.
type profileRequest struct {
	ID string `json:"id"`
}

// metricsSnapshot is the JSON response for GET /stats.
type metricsSnapshot struct {
	Timestamp             int64  `json:"timestamp"`
	LatencyMs             int    `json:"latencyMs"`
	JitterMs              int    `json:"jitterMs"`
	ThroughputBytesPerSec int    `json:"throughputBytesPerSec"`
	Drops                 int    `json:"drops"`
	PacketsTotal          int    `json:"packetsTotal"`
	ProfileName           string `json:"profileName"`
	Idle                  bool   `json:"idle"`
}

// computeSnapshot builds a metricsSnapshot from SimConn state.
func (cs *ControlServer) computeSnapshot() metricsSnapshot {
	cs.mu.Lock()
	defer cs.mu.Unlock()

	now := time.Now()
	stats := cs.simConn.Stats()
	profile := cs.simConn.GetProfile()

	// Throughput: bytes delta / time delta
	dt := now.Sub(cs.lastPoll).Seconds()
	currentBytes := stats.ReadBytes + stats.WriteBytes
	previousBytes := cs.lastStats.ReadBytes + cs.lastStats.WriteBytes
	throughput := 0
	if dt > 0 {
		throughput = int(float64(currentBytes-previousBytes) / dt)
	}
	if throughput < 0 {
		throughput = 0
	}

	// Idle: no new packets since last poll
	currentPackets := stats.ReadPackets + stats.WritePackets
	previousPackets := cs.lastStats.ReadPackets + cs.lastStats.WritePackets
	idle := currentPackets == previousPackets

	// Delay stats: Welford mean + stddev, auto-resets per interval
	delayCount, meanNanos, stddevNanos := cs.simConn.DelaySnapshot()
	latencyMs := 0
	jitterMs := 0
	if delayCount > 0 {
		latencyMs = int(meanNanos / 1_000_000)
		jitterMs = int(stddevNanos / 1_000_000)
	}

	cs.lastStats = stats
	cs.lastPoll = now

	return metricsSnapshot{
		Timestamp:             now.UnixMilli(),
		LatencyMs:             latencyMs,
		JitterMs:              jitterMs,
		ThroughputBytesPerSec: throughput,
		Drops:                 int(stats.ReadDropped + stats.WriteDropped + stats.ReadOverflow),
		PacketsTotal:          int(stats.ReadPackets + stats.WritePackets),
		ProfileName:           profile.Name,
		Idle:                  idle,
	}
}

// handler returns the HTTP handler for the control API.
func (cs *ControlServer) handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("POST /profile", func(w http.ResponseWriter, r *http.Request) {
		var req profileRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, `{"error":"invalid JSON"}`, http.StatusBadRequest)
			return
		}
		if req.ID == "" {
			http.Error(w, `{"error":"id is required"}`, http.StatusBadRequest)
			return
		}

		if !cs.simConn.SetProfile(req.ID) {
			http.Error(w, `{"error":"unknown profile"}`, http.StatusBadRequest)
			return
		}
		cs.simConn.ResetStats()

		// Reset throughput tracking
		cs.mu.Lock()
		cs.lastStats = netsim.Stats{}
		cs.lastPoll = time.Now()
		cs.mu.Unlock()

		profile := cs.simConn.GetProfile()
		w.Header().Set("Content-Type", "application/json")
		resp, _ := json.Marshal(map[string]string{
			"status":  "ok",
			"profile": profile.Name,
		})
		w.Write(resp)
	})

	mux.HandleFunc("GET /stats", func(w http.ResponseWriter, r *http.Request) {
		snap := cs.computeSnapshot()
		w.Header().Set("Content-Type", "application/json")
		resp, _ := json.Marshal(snap)
		w.Write(resp)
	})

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

	return mux
}

// ListenAndServe starts the control API on the given address (blocking).
func (cs *ControlServer) ListenAndServe(addr string) error {
	log.Printf("Control API starting on %s", addr)
	cs.server = &http.Server{Addr: addr, Handler: cs.handler()}
	return cs.server.ListenAndServe()
}

// Shutdown gracefully shuts down the control API server.
func (cs *ControlServer) Shutdown(ctx context.Context) error {
	if cs.server == nil {
		return nil
	}
	return cs.server.Shutdown(ctx)
}
