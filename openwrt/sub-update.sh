#!/bin/sh
# Update the proxy-NN outbounds of /etc/xray/config.json from subscriptions.
#
# /etc/xray/subscriptions.txt: one https URL per line (# comments). Each URL must
# return an xray JSON config (an object or an array of them). Every outbound in it
# that is not freedom/blackhole/dns/loopback becomes proxy-NN, numbered in file order.
#
# Only protocol, settings and streamSettings of proxy-NN are replaced: tag and any
# other local keys of the existing outbound stay. A new reality shortId/spiderX alone
# (providers randomize them per request) does not count as a change. Flat settings (address/port/id at
# the top, newer xray) are converted to vnext/servers for the installed xray.
# proxy-* outbounds that no subscription produces are removed.
#
# A subscription that fails keeps its previous outbounds; which tags belong to which
# URL is remembered in subscriptions.state (first run: line N -> proxy-NN).
#
# The candidate is checked with xray -test; xray is restarted only if the config
# changed, and the old one (config.json.prev) is restored if xray does not come up.
#
# --dry-run: fetch and test, print what would change, touch nothing.

CONF=${XRAY_CONF:-/etc/xray/config.json}
SUBS=/etc/xray/subscriptions.txt
STATE=/etc/xray/subscriptions.state
ASSET=$(uci -q get xray.config.datadir || echo /usr/share/xray)
WORK=/tmp/sub.new
LOCK=/tmp/sub-update.lock

DRY=0
[ "$1" = "--dry-run" ] && DRY=1

log() { logger -t sub-update "$*"; echo "$*"; }
die() { log "ERROR: $*"; exit 1; }

mkdir "$LOCK" 2>/dev/null || { log "already running"; exit 1; }
trap 'rm -rf "$LOCK" "$WORK"' EXIT
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK" || die "cannot create $WORK"

fetch() {
	curl -fsSL -m 30 -o "$2" "$1" 2>/dev/null ||
		curl -fsSL -m 30 --socks5-hostname 127.0.0.1:10808 -o "$2" "$1" 2>/dev/null
}

jq -e '.outbounds | type == "array"' "$CONF" > /dev/null 2>&1 || die "cannot parse $CONF"
[ -f "$SUBS" ] || die "$SUBS not found"
if jq -e 'type == "object"' "$STATE" > /dev/null 2>&1; then
	cp "$STATE" state.json
else
	echo '{}' > state.json
fi

# subs.json: [{url, obs: [outbound...] | null}] in file order
N=0
FAILED=0
echo '[]' > subs.json
set -f
for url in $(sed 's/^[[:space:]]*#.*//; s/[[:space:]]//g' "$SUBS" | grep .); do
	N=$((N + 1))
	obs=null
	if ! fetch "$url" sub.json; then
		log "sub $N: download failed, keeping old outbounds"
	elif ! jq -e '[if type == "array" then .[] else . end | .outbounds[]?
			| select(.protocol | IN("freedom", "blackhole", "dns", "loopback") | not)]
			| if length > 0 then . else error end' sub.json > obs.json 2>/dev/null; then
		log "sub $N: no proxy outbounds in response, keeping old outbounds"
	else
		obs=$(cat obs.json)
	fi
	[ "$obs" = null ] && FAILED=$((FAILED + 1))
	echo "$obs" | jq --arg url "$url" '[input[], {url: $url, obs: .}]' - subs.json > subs.tmp &&
		mv subs.tmp subs.json || die "jq failed"
done
[ $N -gt 0 ] || die "no subscriptions in $SUBS"
[ $FAILED -lt $N ] || die "all $N subscriptions failed, nothing changed"

# new.json: config with rebuilt proxy-NN; newstate.json: {url: [tags]}
jq --slurpfile subs subs.json --slurpfile state state.json '
	def isproxy: (.tag // "") | startswith("proxy-");
	# providers pick a random reality shortId/spiderX per request: not a change
	def noise: if .realitySettings then del(.realitySettings.shortId, .realitySettings.spiderX) else . end;
	def flat:
		if (.protocol | IN("vless", "vmess")) and .settings.vnext == null and .settings.address != null then
			.settings |= {vnext: [{address, port, users: [del(.address, .port)]}]}
		elif (.protocol | IN("trojan", "shadowsocks")) and .settings.servers == null and .settings.address != null then
			.settings |= {servers: [.]}
		else . end;
	. as $c
	| ($c.outbounds | map(select(isproxy)) | INDEX(.tag)) as $old
	| [$subs[0] | to_entries[] | .key as $i | .value
		| {url, obs: (.obs // [($state[0][.url] // ["proxy-\($i + 1 | tostring | if length < 2 then "0" + . else . end)"])[]
			| $old[.] | select(.)])}]
	| [.[] | .url as $u | .obs[] | {url: $u, ob: (. | flat)}]
	| to_entries | map(.value + {tag: "proxy-\(.key + 1 | tostring | if length < 2 then "0" + . else . end)"}) as $new
	| ($new | map(.ob as $ob | $old[.tag] as $was | ($was // $ob) + {tag, protocol: $ob.protocol, settings: $ob.settings}
		| if $ob.streamSettings == null then del(.streamSettings)
		  elif ($was.streamSettings | noise) == ($ob.streamSettings | noise) then .streamSettings = $was.streamSettings
		  else .streamSettings = $ob.streamSettings end)) as $px
	| ($c.outbounds | map(isproxy) | index(true) // 0) as $at
	| ($c.outbounds | to_entries | map(select(.key < $at and (.value | isproxy | not)) | .value)) as $head
	| ($c.outbounds | to_entries | map(select(.key >= $at and (.value | isproxy | not)) | .value)) as $tail
	| {config: ($c | .outbounds = $head + $px + $tail),
	   state: ($new | group_by(.url) | map({key: .[0].url, value: map(.tag)}) | from_entries)}
' "$CONF" > result.json || die "building new config failed"
jq '.config' result.json > new.json && jq '.state' result.json > newstate.json || die "jq failed"
COUNT=$(jq '[.outbounds[] | select(.tag // "" | startswith("proxy-"))] | length' new.json)
[ "$COUNT" -gt 0 ] || die "no proxy outbounds left, refusing to apply"

# one line per changed tag, no credentials
CHANGES=$(jq -rn --slurpfile a "$CONF" --slurpfile b new.json '
	def px: [.outbounds[] | select(.tag // "" | startswith("proxy-"))] | INDEX(.tag);
	def desc: (.settings.vnext // .settings.servers // [.settings])[0] as $s
		| "\(.protocol) \($s.address):\($s.port) \(.streamSettings.network // "tcp")/\(.streamSettings.security // "none")";
	($a[0] | px) as $o | ($b[0] | px) as $n
	| ($o + $n | keys[]) as $t
	| if $o[$t] == null then "\($t): added \($n[$t] | desc)"
	  elif $n[$t] == null then "\($t): removed"
	  elif $o[$t] != $n[$t] then "\($t): updated \($n[$t] | desc)"
	  else empty end')

jq -S . "$CONF" > old.sorted && jq -S . new.json > new.sorted || die "jq failed"
if cmp -s old.sorted new.sorted; then
	[ $DRY = 1 ] || cmp -s newstate.json "$STATE" || cp newstate.json "$STATE"
	log "$N subscriptions ($FAILED failed), $COUNT proxies: unchanged"
	exit 0
fi

XRAY_LOCATION_ASSET="$ASSET" xray run -test -c new.json > xray-test.log 2>&1 ||
	die "xray test of new config failed: $(tail -1 xray-test.log)"

if [ $DRY = 1 ]; then
	echo "$CHANGES"
	echo "dry run: $N subscriptions ($FAILED failed), $COUNT proxies, config test ok, nothing applied"
	exit 0
fi

cp "$CONF" "$CONF.prev" || die "backup failed"
cp new.json "$CONF.tmp" && mv "$CONF.tmp" "$CONF" || die "install $CONF failed"
/etc/init.d/xray restart
sleep 5
if ! pidof xray > /dev/null; then
	cp "$CONF.prev" "$CONF"
	/etc/init.d/xray restart
	die "xray did not start with the new config, restored $CONF.prev"
fi
cp newstate.json "$STATE"
echo "$CHANGES" | while read -r l; do log "$l"; done
log "$N subscriptions ($FAILED failed), $COUNT proxies: updated, xray restarted"
