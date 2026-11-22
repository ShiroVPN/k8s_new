#!/bin/bash
set -euo pipefail

AWG_IFACE=shiro-vpn
K3S_CONFIG=/etc/rancher/k3s/config.yaml
K3S_DROPIN=/etc/systemd/system/k3s.service.d/10-tailscale.conf
RESOLV_K8S=/etc/resolv.k8s.conf

RULES=(
  "to 100.64.0.0/10 lookup 52 priority 5000"
  "to 10.42.0.0/16 lookup main priority 5190"
  "to 10.43.0.0/16 lookup main priority 5190"
  "from 10.42.0.0/16 lookup main priority 5200"
)

die() { echo "$*" >&2; exit 1; }

say() { echo "== $*"; }

apply_rules() {
  say "ip rules"
  if ! ip link show dev "$AWG_IFACE" >/dev/null 2>&1; then
    echo "$AWG_IFACE is down; the conf's PostUp adds the rules"
    return 0
  fi
  local rule probe words
  for rule in "${RULES[@]}"; do
    probe=${rule% priority *}
    if ip rule show | grep -qF "$probe"; then
      echo "present: $rule"
      continue
    fi
    read -r -a words <<<"$rule"
    ip rule add "${words[@]}"
    echo "added:   $rule"
  done
}

configure_k3s() {
  local changed=no current node

  say "k3s node address"
  current=$(sed -n 's/^node-ip: *//p' "$K3S_CONFIG" 2>/dev/null | head -n1)
  if [ "$current" = "$NODE_IP" ]; then
    echo "node-ip is $NODE_IP"
  elif grep -q '^node-ip:' "$K3S_CONFIG" 2>/dev/null; then
    sed -i "s/^node-ip:.*/node-ip: $NODE_IP/" "$K3S_CONFIG"
    echo "node-ip '${current}' -> $NODE_IP"
    changed=yes
  else
    printf 'node-ip: %s\n' "$NODE_IP" >>"$K3S_CONFIG"
    echo "node-ip $NODE_IP written"
    changed=yes
  fi

  say "kubelet resolver"
  if grep -q 'resolv-conf=' "$K3S_CONFIG"; then
    echo "kubelet-arg resolv-conf is set"
  elif grep -q '^kubelet-arg:' "$K3S_CONFIG"; then
    die "$K3S_CONFIG has a kubelet-arg block without resolv-conf; add it by hand"
  else
    printf 'kubelet-arg:\n  - "resolv-conf=%s"\n' "$RESOLV_K8S" >>"$K3S_CONFIG"
    echo "kubelet-arg resolv-conf=$RESOLV_K8S written"
    changed=yes
  fi

  if [ "$(head -n1 "$RESOLV_K8S" 2>/dev/null)" = "nameserver 1.1.1.1" ]; then
    echo "$RESOLV_K8S is set"
  else
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"$RESOLV_K8S"
    echo "$RESOLV_K8S written"
    changed=yes
  fi

  if [ ! -f "$K3S_DROPIN" ]; then
    mkdir -p "$(dirname "$K3S_DROPIN")"
    printf '[Unit]\nAfter=tailscaled.service\nWants=tailscaled.service\n' >"$K3S_DROPIN"
    systemctl daemon-reload
    echo "$K3S_DROPIN written"
    changed=yes
  fi

  node=$(hostname | tr '[:upper:]' '[:lower:]')
  current=$(k3s kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  if [ "$changed" = no ] && [ "$current" = "$NODE_IP" ]; then
    echo "node reports $current"
    return 0
  fi

  say "restarting k3s"
  systemctl restart k3s
  k3s kubectl wait --for=condition=Ready node/"$node" --timeout=180s
  k3s kubectl wait \
    --for=jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'="$NODE_IP" \
    node/"$node" --timeout=180s ||
    die "node did not report $NODE_IP; read: sudo journalctl -u k3s -n 50"
  echo "node reports $NODE_IP"
}

report() {
  local node
  node=$(hostname | tr '[:upper:]' '[:lower:]')
  say "result"
  echo "node ip: $(k3s kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
  echo "resolv:  $(tr '\n' ' ' <"$RESOLV_K8S")"
  echo "tunnel:  $(ip link show dev "$AWG_IFACE" >/dev/null 2>&1 && echo up || echo down)"
}

[ "$(id -u)" -eq 0 ] || die "run this with sudo"
command -v tailscale >/dev/null || die "tailscale is not installed"
NODE_IP=${NODE_IP:-$(tailscale ip -4 | head -n1)}
[ -n "$NODE_IP" ] || die "tailscale has no IPv4 address"
[ -x /usr/local/bin/k3s ] || die "k3s is not installed; run ./deploy.sh init_cluster first"

apply_rules
configure_k3s
report
