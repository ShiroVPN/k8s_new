#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

K3S_VERSION=v1.37.2+k3s1
ARGOCD_VERSION=v3.6.1
NAMESPACE=shiro

k() { sudo k3s kubectl "$@"; }

node_name() { hostname | tr '[:upper:]' '[:lower:]'; }

init_cluster() {
  if ! command -v k3s >/dev/null; then
    curl -sfL https://get.k3s.io |
      INSTALL_K3S_VERSION="$K3S_VERSION" \
      INSTALL_K3S_EXEC="server --disable=traefik --disable=servicelb" sh -
  fi
  sudo systemctl enable --now k3s
  node=$(node_name)
  k wait --for=create node/"$node" --timeout=120s
  k wait --for=condition=Ready node/"$node" --timeout=120s
  k label node "$node" shiro.io/core=true --overwrite

  k create namespace "$NAMESPACE" --dry-run=client -o yaml | k apply -f -
  k create namespace argocd --dry-run=client -o yaml | k apply -f -
  k apply --server-side -n argocd -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
  k -n argocd rollout status deploy/argocd-server --timeout=300s
  k -n argocd patch configmap argocd-cm --type merge \
    -p '{"data":{"kustomize.buildOptions":"--enable-alpha-plugins --enable-exec"}}'

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
  password=$(k -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

  cat <<EOF

Argo CD panel:
  sudo k3s kubectl -n argocd port-forward svc/argocd-server 18080:443 --address 127.0.0.1
  ssh -L 18080:127.0.0.1:18080 <this server>
  https://localhost:18080  admin
  password: ${password:-<argocd-initial-admin-secret not found>}

applications:
  ./deploy.sh run --profile core
  ./deploy.sh run --profile peerhub-wg

new VPN node:
  git clone git@github.com:ShiroVPN/k8s_new.git
  K3S_URL=https://$ip:6443 K3S_TOKEN=$token ./deploy.sh join_cluster --profile peerhub-wg
  ports 6443 to the core, 8472/udp and 10250/tcp both ways - see README
EOF
}

join_cluster() {
  profile=$1
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

  curl -sfL https://get.k3s.io |
    K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" \
    INSTALL_K3S_VERSION="$K3S_VERSION" \
    INSTALL_K3S_EXEC="agent --node-label shiro.io/$profile=true" sh -
  sudo systemctl enable --now k3s-agent

  echo "joined $K3S_URL as shiro.io/$profile=true"
}

peerhub_configure() {
  file="overlays/$1/peerhub-config.yaml"
  [ -f "$file" ] || return 0
  grep -q 'PEERHUB_ID: "00000000' "$file" || return 0

  default_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
  read -r -p "PEERHUB_ID [$default_id]: " peerhub_id
  peerhub_id=${peerhub_id:-$default_id}
  read -r -p "COUNTRY (max 15) [Germany]: " country
  country=${country:-Germany}
  read -r -p "SERVER_NAME (max 15) [local]: " server_name
  server_name=${server_name:-local}
  read -r -p "WG_HOST [0.0.0.0]: " wg_host
  wg_host=${wg_host:-0.0.0.0}
  read -r -p "WG_PORT [51820]: " wg_port
  wg_port=${wg_port:-51820}

  cat > "$file" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: peerhub-config
data:
  PEERHUB_ID: "$peerhub_id"
  COUNTRY: "$country"
  SERVER_NAME: "$server_name"
  WG_HOST: "$wg_host"
  WG_PORT: "$wg_port"
EOF
  echo "wrote $file; commit and push it before Sync"
}

label() {
  profile=$1
  k label node "$(node_name)" "shiro.io/$profile=true" --overwrite
}

run() {
  profile=$1
  peerhub_configure "$profile"
  k apply -f "argocd/$profile.yaml"
  k -n argocd get application "$profile"
  echo "sync it by hand in the Argo CD panel: $profile"
}

case "${1:-}" in
init_cluster) init_cluster ;;
join_cluster) join_cluster "${3:?usage: $0 join_cluster --profile <name>}" ;;
label) label "${3:?usage: $0 label --profile <name>}" ;;
run) run "${3:?usage: $0 run --profile <name>}" ;;
*)
  echo "usage: $0 init_cluster | join_cluster --profile <name> | label --profile <name> | run --profile <name>"
  exit 1
  ;;
esac
