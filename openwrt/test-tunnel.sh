#!/bin/sh
# Test every xray tunnel (proxy-* outbounds) against the direct path and the
# live balancer: latency, exit IP/location, YouTube cache node, download speed.
#
#   ssh root@192.168.1.1 ./test-tunnel.sh          # table
#   ssh root@192.168.1.1 ./test-tunnel.sh --json   # JSON
#
# Each tunnel runs in its own throwaway xray (socks on 127.0.0.1) built from the
# outbound in $XRAY_CONF, so the running service is never touched.

CONF=${XRAY_CONF:-/etc/xray/config.json}
LIVE_PROXY=${LIVE_PROXY:-127.0.0.1:10808}   # mixed inbound of the running xray
BASE_PORT=20800
LAT_N=5
DL_TIME=8

URL_204=https://www.youtube.com/generate_204
URL_MAP='https://redirector.googlevideo.com/report_mapping?di=no'
# IP literal forces an IPv4 exit (proxy may prefer v6); not 1.1.1.1, which the
# live routing sends direct.
URL_TRACE=https://1.0.0.1/cdn-cgi/trace
URL_CF_DL='https://speed.cloudflare.com/__down?bytes=25000000'   # CF caps at 25 MB
URL_G_DL=https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
URL_RU_LAT=https://ya.ru
URL_RU_DL=https://speedtest.selectel.ru/100MB

JSON=0
case "$1" in
	--json) JSON=1 ;;
	"") ;;
	*) echo "usage: $0 [--json]" >&2; exit 2 ;;
esac

for b in curl jq xray; do
	command -v "$b" >/dev/null || { echo "missing: $b" >&2; exit 1; }
done
[ -r "$CONF" ] || { echo "cannot read $CONF" >&2; exit 1; }

WORK=/tmp/test-tunnel.$$
XPID=
mkdir -p "$WORK"
cleanup() {
	[ -n "$XPID" ] && kill "$XPID" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

log() { echo "$*" >&2; }

# Latency: N requests, median/spread of successful ones in ms, plus failures.
# Prints: "median spread fails"
latency() {
	url=$1; shift
	i=0
	: >"$WORK/lat"
	while [ $i -lt $LAT_N ]; do
		curl "$@" -s -o /dev/null --max-time 3 -w '%{http_code} %{time_total}\n' "$url" >>"$WORK/lat"
		i=$((i + 1))
	done
	awk '$1 ~ /^[23]/ { print $2 * 1000 }' "$WORK/lat" | sort -n | awk -v n=$LAT_N '
		{ v[NR] = $1 }
		END {
			if (NR == 0) { print "- - " n; exit }
			printf "%d %d %d\n", v[int((NR + 1) / 2)], v[NR] - v[1], n - NR
		}'
}

# Download for up to DL_TIME seconds, re-fetching the URL while time remains
# (CF caps a single fetch at 25 MB). Prints Mbit/s, "http<code>" if the first
# fetch was refused (e.g. http429 = CF rate limit), or "-".
download() {
	url=$1; shift
	bytes=0 secs=0 n=0 code=
	while [ $n -lt 10 ]; do
		left=$(awk -v t="$secs" -v m=$DL_TIME 'BEGIN { l = m - t; print (l > 0.5 ? l : 0) }')
		[ "$left" = 0 ] && break
		r=$(curl "$@" -s -o /dev/null --max-time "$left" \
			-w '%{http_code} %{size_download} %{time_total}' "$url")
		code=${r%% *} r=${r#* }
		case "$code" in 2*) ;; *) break ;; esac
		bytes=$((bytes + ${r%% *}))
		secs=$(awk -v a="$secs" -v b="${r#* }" 'BEGIN { print a + b }')
		n=$((n + 1))
	done
	case "$bytes:$code" in 0:[13-9]*) echo "http$code"; return ;; esac
	awk -v b=$bytes -v t="$secs" 'BEGIN { if (b > 0 && t > 0) printf "%.1f\n", b * 8 / t / 1e6; else print "-" }'
}

# run_path NAME [curl proxy args...] -> writes $WORK/NAME.res
run_path() {
	name=$1; shift
	log "== $name"

	lat_raw=$(latency "$URL_204" "$@")
	log "   youtube 204: ${lat_raw%% *} ms (fails $(echo "$lat_raw" | cut -d' ' -f3)/$LAT_N)"

	trace=$(curl "$@" -s --max-time 8 "$URL_TRACE")
	ip=$(echo "$trace" | sed -n 's/^ip=//p')
	loc=$(echo "$trace" | sed -n 's/^loc=//p')
	colo=$(echo "$trace" | sed -n 's/^colo=//p')

	if [ -z "$ip" ] && [ "$(echo "$lat_raw" | cut -d' ' -f3)" = "$LAT_N" ]; then
		status=DOWN
		log "   DOWN"
		node=- cf=- g=-
	else
		status=OK
		log "   exit: ${ip:--} ${loc:--}/${colo:--}"
		node=$(curl "$@" -s --max-time 8 "$URL_MAP" | sed -n 's/.*=> *\([^ ]*\).*/\1/p')
		log "   yt node: ${node:--}"
		cf=$(download "$URL_CF_DL" "$@")
		log "   cloudflare: $cf Mbit/s"
		g=$(download "$URL_G_DL" "$@")
		log "   google cdn: $g Mbit/s"
	fi

	set -- $lat_raw
	cat >"$WORK/$name.res" <<-EOF
		status='$status' ip='${ip:--}' loc='${loc:--}' colo='${colo:--}' node='${node:--}'
		lat='$1' spread='$2' fail='$3' cf='$cf' g='$g'
	EOF
	echo "$name" >>"$WORK/paths"
}

# Start a throwaway xray with only this outbound behind a socks inbound.
start_xray() {
	tag=$1 port=$2
	jq --arg tag "$tag" --argjson port "$port" '{
		log: { loglevel: "error" },
		inbounds: [{ listen: "127.0.0.1", port: $port, protocol: "socks",
			settings: { auth: "noauth", udp: false } }],
		outbounds: [ .outbounds[] | select(.tag == $tag) ]
	}' "$CONF" >"$WORK/$tag.json" || return 1
	xray run -c "$WORK/$tag.json" >"$WORK/$tag.log" 2>&1 &
	XPID=$!
	i=0
	while [ $i -lt 5 ]; do
		netstat -ltn 2>/dev/null | grep -q "127.0.0.1:$port " && return 0
		kill -0 "$XPID" 2>/dev/null || break
		sleep 1
		i=$((i + 1))
	done
	return 1
}

stop_xray() {
	[ -n "$XPID" ] && kill "$XPID" 2>/dev/null && wait "$XPID" 2>/dev/null
	XPID=
}

: >"$WORK/paths"

run_path direct

port=$BASE_PORT
for tag in $(jq -r '.outbounds[].tag // empty | select(startswith("proxy-"))' "$CONF"); do
	if start_xray "$tag" "$port"; then
		run_path "$tag" --socks5-hostname "127.0.0.1:$port"
	else
		log "== $tag"
		log "   xray failed to start: $(tail -1 "$WORK/$tag.log")"
		echo "status='XRAY-FAIL' ip=- loc=- colo=- node=- lat=- spread=- fail=$LAT_N cf=- g=-" >"$WORK/$tag.res"
		echo "$tag" >>"$WORK/paths"
	fi
	stop_xray
	port=$((port + 1))
done

run_path balancer --socks5-hostname "$LIVE_PROXY"

log "== russia (direct)"
ru_lat=$(latency "$URL_RU_LAT")
ru_dl=$(download "$URL_RU_DL")
log "   ya.ru: ${ru_lat%% *} ms, selectel: $ru_dl Mbit/s"

# Balancer pick: which tunnel shares the balancer's exit IP.
. "$WORK/balancer.res"
bal_ip=$ip pick='?'
for p in $(cat "$WORK/paths"); do
	[ "$p" = balancer ] && continue
	. "$WORK/$p.res"
	[ "$ip" != - ] && [ "$ip" = "$bal_ip" ] && pick=$p
done
[ "$bal_ip" = - ] && pick=-

set -- $ru_lat
ru_med=$1 ru_spread=$2 ru_fail=$3

if [ $JSON = 1 ]; then
	for p in $(cat "$WORK/paths"); do
		. "$WORK/$p.res"
		jq -n --arg path "$p" --arg status "$status" --arg ip "$ip" --arg loc "$loc" \
			--arg colo "$colo" --arg node "$node" --arg lat "$lat" --arg spread "$spread" \
			--arg fail "$fail" --arg cf "$cf" --arg g "$g" '
			def num: tonumber? // null;
			def str: if . == "-" then null else . end;
			{ path: $path, status: $status, exit_ip: ($ip | str),
			  loc: ($loc | str), colo: ($colo | str), yt_node: ($node | str),
			  lat_ms: ($lat | num), lat_spread_ms: ($spread | num), lat_fail: ($fail | num),
			  cf_mbit: ($cf | num), gcdn_mbit: ($g | num) }
			+ (if $cf | startswith("http") then { cf_note: $cf } else {} end)
			+ (if $g | startswith("http") then { gcdn_note: $g } else {} end)'
	done | jq -s --arg pick "$pick" --arg rm "$ru_med" --arg rs "$ru_spread" \
		--arg rf "$ru_fail" --arg rd "$ru_dl" '
		def num: tonumber? // null;
		{ paths: ., balancer_pick: $pick,
		  ru_direct: { lat_ms: ($rm | num), lat_spread_ms: ($rs | num),
		               lat_fail: ($rf | num), dl_mbit: ($rd | num) } }'
	exit 0
fi

fmt='%-10s %-9s %-16s %-8s %-12s %-12s %-5s %8s %8s\n'
echo
printf "$fmt" PATH STATUS 'EXIT IP' LOC/COLO 'YT NODE' 'YT LAT ms' FAIL 'CF Mbit' 'G Mbit'
for p in $(cat "$WORK/paths"); do
	. "$WORK/$p.res"
	if [ "$lat" = - ]; then l=-; else l="$lat ±$spread"; fi
	printf "$fmt" "$p" "$status" "$ip" "$loc/$colo" "$node" "$l" "$fail/$LAT_N" "$cf" "$g"
done
echo
echo "balancer -> $pick"
echo "russia (direct): ya.ru ${ru_med} ms ±${ru_spread} (fail $ru_fail/$LAT_N), selectel $ru_dl Mbit/s"
