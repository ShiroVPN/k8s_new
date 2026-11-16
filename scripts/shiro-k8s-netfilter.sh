#!/bin/sh
# Keep k3s cluster traffic out of v2raya's transparent proxy.
#
# v2raya redirects *every* packet with dport 53 to 127.0.0.1:52353 and every
# TCP packet to 127.0.0.1:52345, without excluding pod or service CIDRs. Inside
# a pod network namespace those local ports do not exist, so CoreDNS lookups
# die with "connection refused" and Argo CD cannot resolve argocd-repo-server.
#
# v2raya skips packets carrying its own bypass mark 0x80, so we set that mark
# on traffic that must never be proxied:
#   - anything addressed to the cluster CIDRs (pods 10.42/16, services 10.43/16)
#   - DNS leaving a pod or the cni bridge, so CoreDNS can reach its upstream
#   - DNS originating on the host towards the cluster
#
# Run it as root from the repo: it installs itself to /usr/local/sbin, writes
# shiro-k8s-netfilter.service (which runs it after v2raya), enables and starts
# the unit. Executed from the installed path it only (re)creates the table, so
# editing the rules here and running the repo copy again updates the host. The
# table lives in its own namespace, so v2raya does not remove it when it
# rewrites its own rules.
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
