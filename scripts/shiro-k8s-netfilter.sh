#!/bin/sh
set -eu

SELF=/usr/local/sbin/shiro-k8s-netfilter.sh
UNIT=/etc/systemd/system/shiro-k8s-netfilter.service
RESOLV=/etc/resolv.k8s.conf
K3S_CONFIG=/etc/rancher/k3s/config.yaml

apply_rules() {
  nft delete table inet shiro_k8s 2>/dev/null || true

  nft -f - <<'EOF'
table inet shiro_k8s {
        chain pre {
                type filter hook prerouting priority mangle + 10; policy accept;
                ip daddr { 10.42.0.0/16, 10.43.0.0/16 } meta mark set meta mark | 0x00000080
                iifname { "veth*", "cni*" } udp dport 53 meta mark set meta mark | 0x00000080
                iifname { "veth*", "cni*" } tcp dport 53 meta mark set meta mark | 0x00000080
        }

        chain out {
                type filter hook output priority mangle + 10; policy accept;
                ip daddr { 10.42.0.0/16, 10.43.0.0/16 } meta mark set meta mark | 0x00000080
        }
}
EOF
}

install_service() {
  install -m 755 "$0" "$SELF"

  cat >"$UNIT" <<EOF
[Unit]
Description=Keep k3s pod/service traffic out of v2raya transparent proxy
After=v2raya.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SELF
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable shiro-k8s-netfilter
  systemctl restart shiro-k8s-netfilter
  echo "installed $SELF and $UNIT; shiro-k8s-netfilter enabled and started"
}

configure_dns() {
  gateway=$(ip route show default | awk '/^default/ {print $3; exit}')
  if [ -z "$gateway" ]; then
    echo "no default route: cannot pick a CoreDNS upstream" >&2
    return 1
  fi

  echo "nameserver $gateway" >"$RESOLV"
  echo "wrote $RESOLV (nameserver $gateway)"

  if [ -f "$K3S_CONFIG" ]; then
    if grep -q "resolv-conf=$RESOLV" "$K3S_CONFIG"; then
      echo "$K3S_CONFIG already passes $RESOLV to kubelet"
      return 0
    fi
    if grep -q 'kubelet-arg:' "$K3S_CONFIG"; then
      echo "$K3S_CONFIG already has kubelet-arg: add \"resolv-conf=$RESOLV\" by hand" >&2
      return 1
    fi
  fi

  mkdir -p "$(dirname "$K3S_CONFIG")"
  {
    echo 'kubelet-arg:'
    echo "  - \"resolv-conf=$RESOLV\""
  } >>"$K3S_CONFIG"
  echo "added $RESOLV to $K3S_CONFIG"

  if systemctl is-active --quiet k3s; then
    echo "k3s is running: systemctl restart k3s so CoreDNS picks the new upstream"
  fi
}

check_v2raya() {
  if ! nft list table inet v2raya >/dev/null 2>&1; then
    echo "v2raya: no inet v2raya table, nothing to check"
    return 0
  fi

  if nft list table inet v2raya | grep -q 'iifname "veth\*"'; then
    echo "v2raya: remove 'veth*' from Excluded Interface Prefixes, otherwise pod traffic never enters the proxy" >&2
  fi

  if ss -ltn | grep -q '127\.0\.0\.1:52345'; then
    echo "v2raya: the transparent port is loopback-only - turn Port Sharing on" >&2
  fi
}

[ "$(id -u)" -eq 0 ] || {
  echo "run as root: sudo $0" >&2
  exit 1
}

if [ "$0" -ef "$SELF" ]; then
  apply_rules
  exit 0
fi

install_service
configure_dns || true
check_v2raya
