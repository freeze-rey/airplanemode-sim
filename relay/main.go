package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/freeze-rey/airplanemode-sim/relay/netsim"

	masque "github.com/quic-go/masque-go"
	"github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
	"github.com/yosida95/uritemplate/v3"
)

var (
	connCount  atomic.Int64
	proxyCount atomic.Int64
	errCount   atomic.Int64
)

// dialByIP resolves DNS using a public resolver (bypassing system resolver)
// and connects to the IP directly. This avoids the macOS relay routing loop
// where the system resolver tags connections to matched domains, causing the
// relay's own outbound connections to be intercepted by itself.
func dialByIP(ctx context.Context, hostPort string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(hostPort)
	if err != nil {
		host = hostPort
		port = "443"
	}

	if ip := net.ParseIP(host); ip != nil {
		return (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp", hostPort)
	}

	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, "udp", "8.8.8.8:53")
		},
	}

	ips, err := resolver.LookupIPAddr(ctx, host)
	if err != nil {
		return nil, fmt.Errorf("DNS resolve %s: %w", host, err)
	}
	if len(ips) == 0 {
		return nil, fmt.Errorf("no IPs for %s", host)
	}

	target := net.JoinHostPort(ips[0].IP.String(), port)
	log.Printf("  resolved %s -> %s", host, target)
	return (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp", target)
}

func main() {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("failed to resolve home dir: %v", err)
	}
	supportDir := homeDir + "/Library/Application Support/AirplaneMode"
	certFile := supportDir + "/localhost.pem"
	keyFile := supportDir + "/localhost-key.pem"
	masqueAddr := ":4433"
	controlAddr := "localhost:4434"

	if v := os.Getenv("RELAY_ADDR"); v != "" {
		masqueAddr = v
	}
	if v := os.Getenv("CERT_FILE"); v != "" {
		certFile = v
	}
	if v := os.Getenv("KEY_FILE"); v != "" {
		keyFile = v
	}
	if v := os.Getenv("CONTROL_ADDR"); v != "" {
		controlAddr = v
	}

	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		log.Fatalf("failed to load TLS cert: %v", err)
	}

	tlsConf := &tls.Config{
		Certificates: []tls.Certificate{cert},
		NextProtos:   []string{"h3"},
	}

	host := os.Getenv("RELAY_HOST")
	if host == "" {
		host = "localhost"
	}
	tmpl := uritemplate.MustNew("https://" + host + masqueAddr + "/masque?h={target_host}&p={target_port}")

	// Create UDP listener and wrap with SimConn for packet-level conditioning.
	// All QUIC traffic (TCP CONNECT and CONNECT-UDP) is conditioned at the
	// UDP packet level. QUIC congestion control responds naturally to
	// simulated loss/delay. ECN and GSO are preserved through OOB data.
	addr, err := net.ResolveUDPAddr("udp", masqueAddr)
	if err != nil {
		log.Fatalf("invalid address %s: %v", masqueAddr, err)
	}
	udpConn, err := net.ListenUDP("udp", addr)
	if err != nil {
		log.Fatalf("failed to listen UDP %s: %v", masqueAddr, err)
	}
	simConn := netsim.Wrap(udpConn)

	var proxy masque.Proxy

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reqID := connCount.Add(1)

		log.Printf("[req #%d] %s %s %s from %s", reqID, r.Method, r.Proto, r.URL.String(), r.RemoteAddr)

		// Health check
		if r.URL.Path == "/health" && r.Method == http.MethodGet {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"status":"ok","connections":%d,"proxied":%d,"errors":%d}`,
				connCount.Load(), proxyCount.Load(), errCount.Load())
			return
		}

		// CONNECT-UDP (MASQUE, RFC 9298) — for UDP traffic
		if r.Proto == "connect-udp" {
			mreq, err := masque.ParseRequest(r, tmpl)
			if err != nil {
				var perr *masque.RequestParseError
				if errors.As(err, &perr) {
					log.Printf("[req #%d] MASQUE parse error (HTTP %d): %v", reqID, perr.HTTPStatus, perr.Err)
					w.WriteHeader(perr.HTTPStatus)
				} else {
					log.Printf("[req #%d] MASQUE parse error: %v", reqID, err)
					w.WriteHeader(http.StatusBadRequest)
				}
				errCount.Add(1)
				return
			}
			log.Printf("[req #%d] CONNECT-UDP to target: %s", reqID, mreq.Target)
			proxyCount.Add(1)
			if err := proxy.Proxy(w, mreq); err != nil {
				log.Printf("[req #%d] proxy error: %v", reqID, err)
				errCount.Add(1)
			}
			log.Printf("[req #%d] CONNECT-UDP session ended: %s", reqID, mreq.Target)
			return
		}

		// HTTP CONNECT — for TCP traffic (curl, Safari, etc.)
		if r.Method == http.MethodConnect {
			log.Printf("[req #%d] TCP CONNECT to %s", reqID, r.Host)
			proxyCount.Add(1)

			targetConn, err := dialByIP(r.Context(), r.Host)
			if err != nil {
				log.Printf("[req #%d] TCP dial failed: %v", reqID, err)
				w.WriteHeader(http.StatusBadGateway)
				errCount.Add(1)
				return
			}
			defer targetConn.Close()

			w.WriteHeader(http.StatusOK)
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}

			// No per-flow conditioning needed — SimConn handles it at packet level.
			done := make(chan struct{})
			go func() {
				buf := make([]byte, 32768)
				for {
					n, err := targetConn.Read(buf)
					if n > 0 {
						if _, werr := w.Write(buf[:n]); werr != nil {
							break
						}
						if f, ok := w.(http.Flusher); ok {
							f.Flush()
						}
					}
					if err != nil {
						break
					}
				}
				close(done)
			}()

			buf := make([]byte, 32768)
			for {
				n, err := r.Body.Read(buf)
				if n > 0 {
					if _, werr := targetConn.Write(buf[:n]); werr != nil {
						break
					}
				}
				if err != nil {
					break
				}
			}
			<-done
			log.Printf("[req #%d] TCP tunnel closed: %s", reqID, r.Host)
			return
		}

		log.Printf("[req #%d] UNHANDLED: %s %s proto=%s", reqID, r.Method, r.URL.String(), r.Proto)
		w.WriteHeader(http.StatusBadRequest)
	})

	// Create QUIC transport on the SimConn, then HTTP/3 server
	tr := &quic.Transport{Conn: simConn}
	ln, err := tr.ListenEarly(tlsConf, &quic.Config{Allow0RTT: true, EnableDatagrams: true})
	if err != nil {
		log.Fatalf("failed to create QUIC listener: %v", err)
	}

	server := &http3.Server{
		Handler:         handler,
		EnableDatagrams: true,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	controlServer := NewControlServer(simConn)
	go func() {
		if err := controlServer.ListenAndServe(controlAddr); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("control API error: %v", err)
		}
	}()

	go func() {
		<-ctx.Done()
		log.Println("shutting down...")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = controlServer.Shutdown(shutdownCtx)
		_ = server.Shutdown(shutdownCtx)
		proxy.Close()
		_ = ln.Close()
		_ = simConn.Close()
	}()

	log.Printf("MASQUE relay starting on %s (QUIC/HTTP3)", masqueAddr)
	log.Printf("  Control API on %s (HTTP/1.1)", controlAddr)
	log.Printf("  URI template: %s", tmpl.Raw())
	log.Printf("  Host: %s", host)
	log.Printf("  Cert: %s", certFile)
	log.Printf("  Network conditioning: packet-level (SimConn)")

	if err := server.ServeListener(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("server error: %v", err)
	}
	log.Println("relay stopped")
}
