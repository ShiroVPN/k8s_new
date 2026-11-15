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
# Run it after v2raya (see shiro-k8s-netfilter.service) and after every
# v2raya restart; the table lives in its own namespace, so v2raya does not
# remove it when it rewrites its own rules.
set -eu

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
