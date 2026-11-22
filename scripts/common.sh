#!/bin/bash

export K3S_VERSION=v1.37.2+k3s1

DEPLOY_KUBECONFIG=${DEPLOY_KUBECONFIG:-/etc/rancher/k3s/shiro.kubeconfig}

k_admin() { sudo k3s kubectl "$@"; }

k() {
  if sudo test -f "$DEPLOY_KUBECONFIG"; then
    sudo k3s kubectl --kubeconfig "$DEPLOY_KUBECONFIG" "$@"
  else
    k_admin "$@"
  fi
}

node_name() { hostname | tr '[:upper:]' '[:lower:]'; }
