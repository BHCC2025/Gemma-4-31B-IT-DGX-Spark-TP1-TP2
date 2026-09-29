#!/usr/bin/env bash
# kit/lib/netconfig.sh IFACE CIDR [MTU] — give one CX7 port a static IPv4, persistently. Runs ON the node, with sudo.
# NetworkManager (the DGX OS default) gets a dedicated connection "spark-fabric-IFACE"; without NetworkManager a
# netplan file /etc/netplan/60-spark-fabric-IFACE.yaml is written. Only this interface is touched.
set -euo pipefail
IF="${1:?iface}"; CIDR="${2:?cidr}"; MTU="${3:-9000}"
[ -e "/sys/class/net/$IF" ] || { echo "no interface $IF" >&2; exit 2; }
SUDO=""; [ "$(id -u)" = 0 ] || SUDO=sudo
if systemctl is-active --quiet NetworkManager && ! nmcli -t -f DEVICE,STATE device | grep -q "^$IF:unmanaged"; then
  CON="spark-fabric-$IF"
  if nmcli -t -f NAME connection show | grep -qx "$CON"; then
    $SUDO nmcli connection modify "$CON" ipv4.method manual ipv4.addresses "$CIDR" 802-3-ethernet.mtu "$MTU"
  else
    $SUDO nmcli connection add type ethernet ifname "$IF" con-name "$CON" autoconnect yes \
      connection.autoconnect-priority 50 ipv4.method manual ipv4.addresses "$CIDR" ipv4.never-default yes \
      ipv6.method link-local 802-3-ethernet.mtu "$MTU" >/dev/null
  fi
  $SUDO nmcli connection up "$CON" >/dev/null
  echo "$(hostname): $IF = $CIDR (NetworkManager connection $CON)"
else
  F="/etc/netplan/60-spark-fabric-$IF.yaml"
  printf 'network:\n  version: 2\n  ethernets:\n    %s:\n      addresses: [%s]\n      mtu: %s\n' "$IF" "$CIDR" "$MTU" \
    | $SUDO tee "$F" >/dev/null
  $SUDO chmod 600 "$F"
  $SUDO netplan apply
  echo "$(hostname): $IF = $CIDR ($F)"
fi
