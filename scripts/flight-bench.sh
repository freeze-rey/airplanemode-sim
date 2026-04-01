#!/usr/bin/env bash
# Capture raw network metrics on airplane WiFi for netsim calibration.
# Usage: sudo ./scripts/flight-bench.sh [label]
#   label: flight phase identifier (default: "snapshot")
#   Example: sudo ./scripts/flight-bench.sh cruising
# Deps: jq (brew install jq)
# Output: ./traces/flight-YYYYMMDD-HHMMSS-LABEL.json
set -euo pipefail

LABEL="${1:-snapshot}"
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
	for host in 1.1.1.1 api.anthropic.com; do
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
probe_tls_rtt 1.1.1.1 &
probe_tls_rtt api.anthropic.com &
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

for f in rtt-1.1.1.1.jsonl rtt-api.anthropic.com.jsonl bw-down.jsonl bw-up.jsonl; do
	touch "$BENCH_TMP/$f"
done

jq -n \
	--arg label "$LABEL" \
	--arg timestamp "$(cat "$BENCH_TMP/timestamp.txt")" \
	--rawfile cfTrace "$BENCH_TMP/cf-trace.txt" \
	--rawfile uname "$BENCH_TMP/uname.txt" \
	--rawfile dns_cf "$BENCH_TMP/dns-1.1.1.1.txt" \
	--rawfile dns_api "$BENCH_TMP/dns-api.anthropic.com.txt" \
	--rawfile trace_udp_cf "$BENCH_TMP/trace-udp-1.1.1.1.txt" \
	--rawfile trace_udp_api "$BENCH_TMP/trace-udp-api.anthropic.com.txt" \
	--rawfile trace_tcp_cf "$BENCH_TMP/trace-tcp-1.1.1.1.txt" \
	--rawfile trace_tcp_api "$BENCH_TMP/trace-tcp-api.anthropic.com.txt" \
	--slurpfile rtt_cf "$BENCH_TMP/rtt-1.1.1.1.jsonl" \
	--slurpfile rtt_api "$BENCH_TMP/rtt-api.anthropic.com.jsonl" \
	--slurpfile bw_down "$BENCH_TMP/bw-down.jsonl" \
	--slurpfile bw_up "$BENCH_TMP/bw-up.jsonl" \
	--rawfile netstat_before "$BENCH_TMP/netstat-before.txt" \
	--rawfile netstat_after "$BENCH_TMP/netstat-after.txt" \
	'{
        version: 1,
        metadata: {
            timestamp: $timestamp,
            label: $label,
            cfTrace: $cfTrace,
            uname: $uname
        },
        dns: {
            cloudflare: $dns_cf,
            anthropic: $dns_api
        },
        traceroute: {
            udp: {
                cloudflare: $trace_udp_cf,
                anthropic: $trace_udp_api
            },
            tcp: {
                cloudflare: $trace_tcp_cf,
                anthropic: $trace_tcp_api
            }
        },
        latency: {
            cloudflare: $rtt_cf,
            anthropic: $rtt_api
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
