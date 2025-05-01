#!/bin/sh

logger -p notice -t "$(basename "$0")" "Activate '${table}' routing tables"
logger -p notice -t "$(basename "$0")" "Activate '${type}' routing types"

[ "$table" != "mangle" ] && [ "$table" != "nat" ] && exit

# $type is `iptables` or `ip6tables`
/opt/etc/init.d/S99sing-box firewall_"$type"

