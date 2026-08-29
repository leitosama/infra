# OpenWRT

## Strip config 
```
jq '.outbounds |= map(del(.settings, .streamSettings))' /etc/xray/config.json
```
