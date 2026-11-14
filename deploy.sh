#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

K3S_VERSION=v1.37.2+k3s1
ARGOCD_VERSION=v3.6.1
NAMESPACE=shiro
FORWARD_DIR=${TMPDIR:-/tmp}/shiro-forward

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

  # Elasticsearch mmaps its indices and refuses to start below this limit.
  sudo sysctl -w vm.max_map_count=262144 >/dev/null

  k create namespace "$NAMESPACE" --dry-run=client -o yaml | k apply -f -
  k create namespace argocd --dry-run=client -o yaml | k apply -f -
  k apply --server-side -n argocd -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
  k -n argocd rollout status deploy/argocd-server --timeout=300s
  # Short reconciliation so a push to the dev branch lands in a minute.
  k -n argocd patch configmap argocd-cm --type merge \
    -p '{"data":{"kustomize.buildOptions":"--enable-alpha-plugins --enable-exec","timeout.reconciliation":"60s"}}'

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
  ./deploy.sh forward argocd
  ssh -L 18080:127.0.0.1:18080 <this server>
  https://localhost:18080  admin
  password: ${password:-<argocd-initial-admin-secret not found>}

applications:
  ./deploy.sh run --profile core
  ./deploy.sh run --profile peerhub-wg
  ./deploy.sh run --profile observability

panels:
  ./deploy.sh forward          # all of them on 127.0.0.1:18081-18087
  ./deploy.sh forward stop

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
  profile=$1
  case $profile in
  peerhub-*) ;;
  *) return 0 ;;
  esac

  file="overlays/$profile/peerhub-config.yaml"
  if [ ! -f "$file" ]; then
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
    echo "wrote $file"
  fi

  namespace="shiro-$profile"
  k create namespace "$namespace" --dry-run=client -o yaml | k apply -f -
  k apply -n "$namespace" -f "$file"
}

label() {
  profile=$1
  k label node "$(node_name)" "shiro.io/$profile=true" --overwrite
}

run() {
  profile=$1
  peerhub_configure "$profile"
  # The file on disk comes from the current branch, so say out loud which
  # branch Argo CD is about to follow.
  branch=$(git branch --show-current 2>/dev/null || echo "detached")
  revision=$(sed -n 's/^ *targetRevision: *//p' "argocd/$profile.yaml")
  echo "applying argocd/$profile.yaml from branch '$branch' (targetRevision: $revision)"
  k apply -f "argocd/$profile.yaml"
  k -n argocd get application "$profile"
  echo "sync it by hand in the Argo CD panel: $profile"
}

# name namespace target container-port local-port password
# password=no panels have no authentication of their own; they are skipped by
# default and only come up with --all.
forward_targets() {
  cat <<EOF
argocd argocd svc/argocd-server 443 18080 yes
grafana observability svc/grafana 3000 18081 yes
jaeger observability svc/jaeger 16686 18082 no
prometheus observability svc/prometheus 9090 18083 no
elasticsearch observability svc/elasticsearch 9200 18084 no
rabbitmq shiro svc/rabbitmq 15672 18085 yes
cloudbeaver shiro svc/cloudbeaver 8978 18086 yes
wg-easy shiro-peerhub-wg deploy/wg-easy 51821 18087 yes
EOF
}

forward_stop() {
  for pid_file in "$FORWARD_DIR"/*.pid; do
    [ -e "$pid_file" ] || continue
    sudo kill "$(cat "$pid_file")" 2>/dev/null || true
    rm -f "$pid_file"
    echo "stopped $(basename "$pid_file" .pid)"
  done
}

forward_start() {
  mkdir -p "$FORWARD_DIR"

  all=no
  while [ "${1:-}" = "--all" ]; do
    all=yes
    shift
  done

  targets=$(forward_targets)
  if [ $# -eq 0 ]; then
    if [ "$all" = yes ]; then
      # shellcheck disable=SC2046
      set -- $(echo "$targets" | cut -d' ' -f1)
    else
      # shellcheck disable=SC2046
      set -- $(echo "$targets" | awk '$6 == "yes" { print $1 }')
    fi
  fi

  # Resolve every name first: a typo must not trigger a password prompt.
  resolved=""
  for name in "$@"; do
    line=$(echo "$targets" | awk -v name="$name" '$1 == name')
    if [ -z "$line" ]; then
      echo "unknown panel: $name" >&2
      echo "available: $(echo "$targets" | cut -d' ' -f1 | tr '\n' ' ')" >&2
      exit 1
    fi
    case $(echo "$line" | cut -d' ' -f6) in
    no)
      if [ "$all" = no ]; then
        echo "skip $name: no password, use --all to forward it anyway" >&2
        continue
      fi
      ;;
    esac
    resolved="$resolved$line"$'\n'
  done

  # Forwards start in the background and cannot answer a password prompt.
  sudo -v

  while read -r name namespace target port local_port _; do
    [ -n "$name" ] || continue
    pid_file="$FORWARD_DIR/$name.pid"
    if [ -f "$pid_file" ] && sudo kill -0 "$(cat "$pid_file")" 2>/dev/null; then
      echo "$name is already forwarded on $local_port"
      continue
    fi
    rm -f "$pid_file"

    sudo k3s kubectl -n "$namespace" port-forward "$target" \
      "$local_port:$port" --address 127.0.0.1 \
      >"$FORWARD_DIR/$name.log" 2>&1 &
    echo $! >"$pid_file"
    echo "$name -> http://127.0.0.1:$local_port"
  done <<<"$resolved"
}

case "${1:-}" in
init_cluster) init_cluster ;;
join_cluster) join_cluster "${3:?usage: $0 join_cluster --profile <name>}" ;;
label) label "${3:?usage: $0 label --profile <name>}" ;;
run) run "${3:?usage: $0 run --profile <name>}" ;;
forward)
  if [ "${2:-}" = "stop" ]; then
    forward_stop
  else
    shift
    forward_start "$@"
  fi
  ;;
*)
  cat <<EOF
usage: $0 <command>

  init_cluster                       install k3s, Argo CD and KSOPS
  join_cluster --profile <name>      join an existing cluster
  label --profile <name>             mark this node for a profile
  run --profile <name>               create the Argo CD Application
  forward [--all] [panel...]         port-forward panels, default is the ones
                                     with a password
  forward stop                       stop every forward
EOF
  exit 1
  ;;
esac
