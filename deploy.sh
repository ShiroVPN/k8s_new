#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

K3S_VERSION=v1.37.2+k3s1
ARGOCD_VERSION=v3.6.1
NAMESPACE=shiro

k() { sudo k3s kubectl "$@"; }

init_cluster() {
  if ! command -v k3s >/dev/null; then
    curl -sfL https://get.k3s.io |
      INSTALL_K3S_VERSION="$K3S_VERSION" \
      INSTALL_K3S_EXEC="server --disable=traefik --disable=servicelb" sh -
  fi
  sudo systemctl enable --now k3s
  node=$(hostname)
  k wait --for=create node/"$node" --timeout=120s
  k wait --for=condition=Ready node/"$node" --timeout=120s
  k label node "$node" shiro.io/core=true --overwrite

  k create namespace "$NAMESPACE" --dry-run=client -o yaml | k apply -f -
  k create namespace argocd --dry-run=client -o yaml | k apply -f -
  k apply --server-side -n argocd -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
  k -n argocd rollout status deploy/argocd-server --timeout=300s

  key=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
  if [ ! -f "$key" ]; then
    echo "sops age key not found: $key"
    echo "put the private key there or set SOPS_AGE_KEY_FILE, then re-run ./deploy.sh init_cluster"
    exit 1
  fi
  k -n argocd create secret generic sops-age \
    --from-file=keys.txt="$key" --dry-run=client -o yaml | k apply -f -
  k -n argocd patch deploy argocd-repo-server --patch-file argocd/ksops-patch.yaml
  k -n argocd rollout status deploy/argocd-repo-server --timeout=300s

  ip=$(k get nodes -o jsonpath='{range .items[0].status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}' | head -n1)
  token=$(sudo cat /var/lib/rancher/k3s/server/node-token)

  cat <<EOF

Argo CD panel:
  sudo k3s kubectl -n argocd port-forward svc/argocd-server 18080:443 --address 127.0.0.1
  ssh -L 18080:127.0.0.1:18080 <this server>
  https://localhost:18080  admin
  password: sudo k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

applications:
  ./deploy.sh run --profile core
  ./deploy.sh run --profile peerhub-wg

new VPN node:
  git clone git@github.com:ShiroVPN/k8s_new.git
  K3S_URL=https://$ip:6443 K3S_TOKEN=$token ./deploy.sh join_cluster --profile peerhub-wg-2
  ports 6443 to the core, 8472/udp and 10250/tcp both ways - see README
EOF
}

join_cluster() {
  profile=$1
  : "${K3S_URL:?set K3S_URL, printed by deploy.sh init_cluster}"
  : "${K3S_TOKEN:?set K3S_TOKEN, printed by deploy.sh init_cluster}"

  curl -sfL https://get.k3s.io |
    K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" \
    INSTALL_K3S_VERSION="$K3S_VERSION" \
    INSTALL_K3S_EXEC="agent --node-label shiro.io/$profile=true" sh -
  sudo systemctl enable --now k3s-agent

  echo "joined $K3S_URL as shiro.io/$profile=true"
}

run() {
  profile=$1
  k apply -f "argocd/$profile.yaml"
  k -n argocd get application "$profile"
  echo "sync it by hand in the Argo CD panel: $profile"
}

case "${1:-}" in
init_cluster) init_cluster ;;
join_cluster) join_cluster "${3:?usage: $0 join_cluster --profile <name>}" ;;
run) run "${3:?usage: $0 run --profile <name>}" ;;
*)
  echo "usage: $0 init_cluster | join_cluster --profile <name> | run --profile <name>"
  exit 1
  ;;
esac
