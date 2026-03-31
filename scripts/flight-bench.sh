#!/usr/bin/env bash
# Capture raw network metrics on airplane WiFi for netsim calibration.
# Usage: sudo ./scripts/flight-bench.sh [label]
#   label: flight phase identifier (default: "snapshot")
#   Example: sudo ./scripts/flight-bench.sh cruising
# Deps: jq (brew install jq)
# Output: ./traces/flight-YYYYMMDD-HHMMSS-LABEL.json
set -euo pipefail

LABEL="${1:-snapshot}"
# Optional: set YOUR_SERVER to a host you control for PEP detection.
# The script probes a non-standard TCP port to measure raw satellite RTT
# and detect Performance Enhancing Proxies. Leave empty to skip.
YOUR_SERVER="${YOUR_SERVER:-}"
SAMPLES=20
DL_SAMPLES=5
UL_SAMPLES=3
DL_SIZE=1000000
UL_SIZE=500000
OUTDIR="./traces"
BENCH_TMP=$(mktemp -d)
trap 'rm -rf "$BENCH_TMP"' EXIT

CURL_FMT='{"dns_s":%{time_namelookup},"tcp_s":%{time_connect},"tls_s":%{time_appconnect},"ttfb_s":%{time_starttransfer},"total_s":%{time_total},"http":%{http_code}}'

# ── Probe functions ──────────────────────────────────────────────

probe_metadata() {
	date -u +%Y-%m-%dT%H:%M:%SZ >"$BENCH_TMP/timestamp.txt"
	curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace >"$BENCH_TMP/cf-trace.txt" 2>&1 || echo "FAILED" >"$BENCH_TMP/cf-trace.txt"
	uname -a >"$BENCH_TMP/uname.txt"
	for host in 1.1.1.1 api.anthropic.com${YOUR_SERVER:+ $YOUR_SERVER}; do
		dig +noall +stats +answer "$host" >"$BENCH_TMP/dns-$host.txt" 2>&1 || true
	done
	echo "  metadata done" >&2
}

probe_traceroute() {
	local host=$1
	# UDP traceroute works without sudo on macOS
	traceroute -n -w 5 -q 3 -m 20 "$host" \
		>"$BENCH_TMP/trace-udp-$host.txt" 2>&1 || true
	# TCP traceroute (port 443) is more reliable on restrictive networks but needs sudo
	if sudo -n true 2>/dev/null; then
		sudo traceroute -T -p 443 -n -w 5 -q 3 -m 20 "$host" \
			2>&1 | tee "$BENCH_TMP/trace-tcp-$host.txt" >/dev/null || true
	else
		echo "SKIPPED: sudo required" >"$BENCH_TMP/trace-tcp-$host.txt"
	fi
	echo "  traceroute $host done" >&2
}

probe_tls_rtt() {
	local host=$1
	for i in $(seq 1 "$SAMPLES"); do
		ts=$(date +%s)
		result=$(curl -w "$CURL_FMT" -o /dev/null -s --max-time 15 \
			--connect-timeout 10 "https://$host/" 2>/dev/null) || true
		echo "$result" | jq -c --argjson ts "$ts" --argjson i "$i" \
			'. + {ts: $ts, i: $i}' >>"$BENCH_TMP/rtt-$host.jsonl" 2>/dev/null ||
			echo "{\"ts\":$ts,\"i\":$i,\"error\":\"parse\"}" >>"$BENCH_TMP/rtt-$host.jsonl"
		tls_val=$(echo "$result" | jq -r '.tls_s // "FAIL"' 2>/dev/null) || tls_val="PARSE_ERR"
		printf "  TLS %-25s [%d/%d] tls=%ss\n" "$host" "$i" "$SAMPLES" "$tls_val" >&2
	done
}

probe_server_rtt() {
	# TCP connect to a non-standard port (firewall REJECT, no service).
	# Measures raw satellite RTT and detects PEP behavior:
	#   - ECONNREFUSED in ~560ms = no PEP, real satellite RTT
	#   - connect() succeeds in ~5ms then resets = PEP is proxying
	# Requires YOUR_SERVER to be set.
	[ -z "$YOUR_SERVER" ] && return
	for i in $(seq 1 "$SAMPLES"); do
		python3 -c "
import socket, time, json
t0 = time.monotonic()
try:
    s = socket.create_connection(('$YOUR_SERVER', 22223), timeout=10)
    tc = time.monotonic()
    s.close()
    print(json.dumps({'ts': int(time.time()), 'i': $i,
        'connect_s': round(tc-t0, 4), 'result': 'connected', 'pep': True}))
except ConnectionRefusedError:
    t1 = time.monotonic()
    print(json.dumps({'ts': int(time.time()), 'i': $i,
        'connect_s': round(t1-t0, 4), 'result': 'refused', 'pep': False}))
except socket.timeout:
    t1 = time.monotonic()
    print(json.dumps({'ts': int(time.time()), 'i': $i,
        'connect_s': round(t1-t0, 4), 'result': 'timeout'}))
except Exception as e:
    print(json.dumps({'ts': int(time.time()), 'i': $i, 'error': str(e)}))
" >>"$BENCH_TMP/rtt-server.jsonl" || true
		printf "  TCP $YOUR_SERVER:22223 [%d/%d]\n" "$i" "$SAMPLES" >&2
	done
}

probe_bandwidth_down() {
	local fmt='{"bytes":%{size_download},"time_s":%{time_total},"speed_bps":%{speed_download}}'
	for i in $(seq 1 "$DL_SAMPLES"); do
		ts=$(date +%s)
		result=$(curl -w "$fmt" -o /dev/null -s --max-time 30 \
			"https://speed.cloudflare.com/__down?measId=$i&bytes=$DL_SIZE" \
			2>/dev/null) || true
		echo "$result" | jq -c --argjson ts "$ts" --argjson i "$i" \
			'. + {ts: $ts, i: $i}' >>"$BENCH_TMP/bw-down.jsonl" 2>/dev/null ||
			echo "{\"ts\":$ts,\"i\":$i,\"error\":\"parse\"}" >>"$BENCH_TMP/bw-down.jsonl"
		printf "  DL [%d/%d] done\n" "$i" "$DL_SAMPLES" >&2
	done
}

probe_bandwidth_up() {
	for i in $(seq 1 "$UL_SAMPLES"); do
		ts=$(date +%s)
		result=$(dd if=/dev/urandom bs="$UL_SIZE" count=1 2>/dev/null |
			curl -w '{"time_s":%{time_total},"speed_bps":%{speed_upload}}' \
				-X POST --data-binary @- -o /dev/null -s --max-time 60 \
				"https://speed.cloudflare.com/__up" \
				2>/dev/null) || true
		echo "$result" | jq -c --argjson ts "$ts" --argjson i "$i" --argjson bytes "$UL_SIZE" \
			'. + {ts: $ts, i: $i, sent_bytes: $bytes}' >>"$BENCH_TMP/bw-up.jsonl" 2>/dev/null ||
			echo "{\"ts\":$ts,\"i\":$i,\"error\":\"parse\"}" >>"$BENCH_TMP/bw-up.jsonl"
		printf "  UL [%d/%d] done\n" "$i" "$UL_SAMPLES" >&2
	done
}

# ── Main ─────────────────────────────────────────────────────────

echo "=== flight-bench — label=$LABEL ==="
echo ""

netstat -s -p tcp >"$BENCH_TMP/netstat-before.txt" 2>&1 || true

echo "--- Parallel: metadata + traceroute + RTT ---"
probe_metadata &
probe_traceroute 1.1.1.1 &
probe_traceroute api.anthropic.com &
if [ -n "$YOUR_SERVER" ]; then probe_traceroute "$YOUR_SERVER" & fi
probe_tls_rtt 1.1.1.1 &
probe_tls_rtt api.anthropic.com &
probe_server_rtt &
wait
echo "  done."
echo ""

echo "--- Bandwidth (sequential) ---"
probe_bandwidth_down
probe_bandwidth_up
echo "  done."
echo ""

netstat -s -p tcp >"$BENCH_TMP/netstat-after.txt" 2>&1 || true

# ── Assemble JSON ────────────────────────────────────────────────

mkdir -p "$OUTDIR"
OUTFILE="$OUTDIR/flight-$(date +%Y%m%d-%H%M%S)-${LABEL}.json"

for f in rtt-1.1.1.1.jsonl rtt-api.anthropic.com.jsonl rtt-server.jsonl bw-down.jsonl bw-up.jsonl; do
	touch "$BENCH_TMP/$f"
done

# Create empty placeholder files for optional server probes
if [ -z "$YOUR_SERVER" ]; then
	for prefix in dns trace-udp trace-tcp; do
		echo "SKIPPED: YOUR_SERVER not set" >"$BENCH_TMP/$prefix-server.txt"
	done
else
	cp "$BENCH_TMP/dns-$YOUR_SERVER.txt" "$BENCH_TMP/dns-server.txt" 2>/dev/null || echo "MISSING" >"$BENCH_TMP/dns-server.txt"
	cp "$BENCH_TMP/trace-udp-$YOUR_SERVER.txt" "$BENCH_TMP/trace-udp-server.txt" 2>/dev/null || echo "MISSING" >"$BENCH_TMP/trace-udp-server.txt"
	cp "$BENCH_TMP/trace-tcp-$YOUR_SERVER.txt" "$BENCH_TMP/trace-tcp-server.txt" 2>/dev/null || echo "MISSING" >"$BENCH_TMP/trace-tcp-server.txt"
fi

jq -n \
	--arg label "$LABEL" \
	--arg server "${YOUR_SERVER:-none}" \
	--arg timestamp "$(cat "$BENCH_TMP/timestamp.txt")" \
	--rawfile cfTrace "$BENCH_TMP/cf-trace.txt" \
	--rawfile uname "$BENCH_TMP/uname.txt" \
	--rawfile dns_cf "$BENCH_TMP/dns-1.1.1.1.txt" \
	--rawfile dns_api "$BENCH_TMP/dns-api.anthropic.com.txt" \
	--rawfile dns_server "$BENCH_TMP/dns-server.txt" \
	--rawfile trace_udp_cf "$BENCH_TMP/trace-udp-1.1.1.1.txt" \
	--rawfile trace_udp_api "$BENCH_TMP/trace-udp-api.anthropic.com.txt" \
	--rawfile trace_udp_server "$BENCH_TMP/trace-udp-server.txt" \
	--rawfile trace_tcp_cf "$BENCH_TMP/trace-tcp-1.1.1.1.txt" \
	--rawfile trace_tcp_api "$BENCH_TMP/trace-tcp-api.anthropic.com.txt" \
	--rawfile trace_tcp_server "$BENCH_TMP/trace-tcp-server.txt" \
	--slurpfile rtt_cf "$BENCH_TMP/rtt-1.1.1.1.jsonl" \
	--slurpfile rtt_api "$BENCH_TMP/rtt-api.anthropic.com.jsonl" \
	--slurpfile rtt_server "$BENCH_TMP/rtt-server.jsonl" \
	--slurpfile bw_down "$BENCH_TMP/bw-down.jsonl" \
	--slurpfile bw_up "$BENCH_TMP/bw-up.jsonl" \
	--rawfile netstat_before "$BENCH_TMP/netstat-before.txt" \
	--rawfile netstat_after "$BENCH_TMP/netstat-after.txt" \
	'{
        version: 1,
        metadata: {
            timestamp: $timestamp,
            label: $label,
            server: $server,
            cfTrace: $cfTrace,
            uname: $uname
        },
        dns: {
            cloudflare: $dns_cf,
            anthropic: $dns_api,
            server: $dns_server
        },
        traceroute: {
            udp: {
                cloudflare: $trace_udp_cf,
                anthropic: $trace_udp_api,
                server: $trace_udp_server
            },
            tcp: {
                cloudflare: $trace_tcp_cf,
                anthropic: $trace_tcp_api,
                server: $trace_tcp_server
            }
        },
        latency: {
            cloudflare: $rtt_cf,
            anthropic: $rtt_api,
            server: $rtt_server
        },
        bandwidth: {
            download: $bw_down,
            upload: $bw_up
        },
        netstat: {
            before: $netstat_before,
            after: $netstat_after
        }
    }' >"$OUTFILE"

echo "Saved to $OUTFILE ($(du -h "$OUTFILE" | cut -f1))"
