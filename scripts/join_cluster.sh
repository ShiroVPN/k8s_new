#!/bin/bash

join_cluster() {
  local node exec_args tailnet resolv=/etc/resolv.k8s.conf

  if [ $# -gt 0 ]; then
    echo "usage: ./deploy.sh join_cluster"
    exit 1
  fi

  if [ -z "${K3S_URL:-}" ]; then
    printf 'K3S_URL (https://<core>:6443): ' >&2
    read -r K3S_URL
  fi
  if [ -z "${K3S_TOKEN:-}" ]; then
    printf 'K3S_TOKEN: ' >&2
    read -r -s K3S_TOKEN
    printf '\n' >&2
  fi
  : "${K3S_URL:?K3S_URL is empty}"
  : "${K3S_TOKEN:?K3S_TOKEN is empty}"

  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' |
    sudo tee "$resolv" >/dev/null
  exec_args="agent --kubelet-arg=resolv-conf=$resolv"
  tailnet=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  if [ -n "$tailnet" ]; then
    exec_args="$exec_args --node-ip=$tailnet --flannel-iface=tailscale0"
  fi

  curl -sfL https://get.k3s.io |
    K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" \
    INSTALL_K3S_VERSION="$K3S_VERSION" \
    INSTALL_K3S_EXEC="$exec_args" sh -
  sudo systemctl enable --now k3s-agent

  node=$(node_name)
  if [ -n "${DEPLOY_KUBECONFIG_B64:-}" ]; then
    printf '%s' "$DEPLOY_KUBECONFIG_B64" | base64 -d |
      sudo tee "$DEPLOY_KUBECONFIG" >/dev/null
    sudo chmod 600 "$DEPLOY_KUBECONFIG"
    k wait --for=create node/"$node" --timeout=120s
    k wait --for=condition=Ready node/"$node" --timeout=120s
  else
    echo "DEPLOY_KUBECONFIG_B64 is empty: ./deploy.sh run cannot reach the API" >&2
  fi

  echo "joined $K3S_URL as $node"
}
