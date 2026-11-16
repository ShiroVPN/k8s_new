#!/bin/sh
set -eu

SELF=/usr/local/sbin/shiro-k8s-netfilter.sh
UNIT=/etc/systemd/system/shiro-k8s-netfilter.service

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

[ "$(id -u)" -eq 0 ] || {
  echo "run as root: sudo $0" >&2
  exit 1
}

if [ "$0" -ef "$SELF" ]; then
  apply_rules
else
  install_service
fi
