# OpenWRT

## Strip config 
```
jq '.outbounds |= map(del(.settings, .streamSettings))' /etc/xray/config.json
```

## PAC for Proxy Switcher
`proxy.pac` is built by `geo.yaml` (`geo2pac.py`) from the same lists as the geo files:
geosite/geoip matches go `DIRECT`, everything else goes to `SOCKS5 127.0.0.1:9050`.
Change the proxy by editing `var PROXY` at the top of the file (or `-p` in the workflow).
```
python3 openwrt/geo2pac.py <dir with geosite-*.txt and geoip *.txt> -p "SOCKS5 127.0.0.1:9050" -o proxy.pac
```
