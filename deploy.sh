#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

K3S_VERSION=v1.37.2+k3s1
ARGOCD_VERSION=v3.6.1
NAMESPACE=shiro
FORWARD_DIR=${TMPDIR:-/tmp}/shiro-forward
FORWARD_ADDRESS=${FORWARD_ADDRESS:-127.0.0.1}
IMAGE_CACHE=${IMAGE_CACHE:-/var/lib/shiro-k8s-images.tar}

k() { sudo k3s kubectl "$@"; }

node_name() { hostname | tr '[:upper:]' '[:lower:]'; }

k3s_installed() {
  [ -x /usr/local/bin/k3s ] && [ -f /etc/systemd/system/k3s.service ]
}

init_cluster() {
  if ! k3s_installed; then
    curl -sfL https://get.k3s.io |
      INSTALL_K3S_VERSION="$K3S_VERSION" \
      INSTALL_K3S_EXEC="server --disable=traefik --disable=servicelb" sh -
  fi
  sudo systemctl enable --now k3s
  node=$(node_name)
  k wait --for=create node/"$node" --timeout=120s
  k wait --for=condition=Ready node/"$node" --timeout=120s
  k label node "$node" shiro.io/core=true --overwrite

  sudo sysctl -w vm.max_map_count=262144 >/dev/null

  k create namespace "$NAMESPACE" --dry-run=client -o yaml | k apply -f -
  k create namespace argocd --dry-run=client -o yaml | k apply -f -
  k apply --server-side -n argocd -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
  k -n argocd rollout status deploy/argocd-server --timeout=300s
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
  ./deploy.sh run --env prod
  ./deploy.sh run --env dev

panels:
  ./deploy.sh forward          # all of them on 127.0.0.1:18081-18088
  ./deploy.sh forward stop

new VPN node:
  git clone git@github.com:ShiroVPN/k8s_new.git
  K3S_URL=https://$ip:6443 K3S_TOKEN=$token ./deploy.sh join_cluster --profile vpn-node
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
  vpn-*) ;;
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
    read -r -p "CONNECTION_TYPE [xui]: " connection_type
    connection_type=${connection_type:-xui}

    default_panel_path="/$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-8)"
    read -r -p "XUI_WEB_BASE_PATH [$default_panel_path]: " web_base_path
    web_base_path=${web_base_path:-$default_panel_path}
    default_sub_path="/$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-8)"
    read -r -p "XUI_SUB_PATH [$default_sub_path]: " sub_path
    sub_path=${sub_path:-$default_sub_path}
    read -r -p "XUI_SUBSCRIPTION_HOST (node host or IP, no scheme): " subscription_host
    : "${subscription_host:?XUI_SUBSCRIPTION_HOST is empty}"
    read -r -p "XUI_INBOUND_IDS (empty = every inbound): " inbound_ids
    read -r -p "XUI_VERIFY [true]: " xui_verify
    xui_verify=${xui_verify:-true}
    read -r -p "XUI_REALITY_TARGET (host:443): " reality_target
    : "${reality_target:?XUI_REALITY_TARGET is empty}"
    default_server_names=${reality_target%:*}
    read -r -p "XUI_REALITY_SERVER_NAMES [$default_server_names]: " server_names
    server_names=${server_names:-$default_server_names}

    web_base_path="/${web_base_path#/}"
    web_base_path="${web_base_path%/}"
    sub_path="/${sub_path#/}"
    sub_path="${sub_path%/}"

    cat > "$file" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: peerhub-config
data:
  PEERHUB_ID: "$peerhub_id"
  COUNTRY: "$country"
  SERVER_NAME: "$server_name"
  CONNECTION_TYPE: "$connection_type"
  WG_HOST: "$wg_host"
  WG_PORT: "$wg_port"
  XUI_WEB_BASE_PATH: "$web_base_path"
  XUI_SUB_PATH: "$sub_path"
  XUI_URL: "http://xui:2053$web_base_path"
  XUI_SUBSCRIPTION_BASE_URL: "http://$subscription_host:2096$sub_path"
  XUI_INBOUND_IDS: "$inbound_ids"
  XUI_VERIFY: "$xui_verify"
  XUI_REALITY_TARGET: "$reality_target"
  XUI_REALITY_SERVER_NAMES: "$server_names"
EOF
    echo "wrote $file"
  fi

  if ! grep -q '^  CONNECTION_TYPE:' "$file"; then
    echo "$file predates the 3xui keys; delete it and run again"
    exit 1
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
  env=$1
  set_file="argocd/applicationset-$env.yaml"
  if [ ! -f "$set_file" ]; then
    echo "no such environment: $env"
    echo "usage: $0 run --env dev|prod"
    exit 1
  fi
  for dir in overlays/vpn-*; do
    [ -d "$dir" ] || continue
    peerhub_configure "$(basename "$dir")"
  done
  branch=$(git branch --show-current 2>/dev/null || echo "detached")
  revision=$(sed -n 's/^ *targetRevision: *//p' "$set_file")
  echo "applying $set_file from branch '$branch' (targetRevision: $revision, env $env)"
  k apply -f "$set_file"
  k -n argocd get applications
}

forward_targets() {
  cat <<EOF
argocd argocd svc/argocd-server 443 18080 yes
grafana observability svc/grafana 3000 18081 yes
jaeger observability svc/jaeger 16686 18082 no
prometheus observability svc/prometheus 9090 18083 no
elasticsearch observability svc/elasticsearch 9200 18084 no
rabbitmq shiro svc/rabbitmq 15672 18085 yes
pgadmin shiro svc/pgadmin 80 18086 yes
wg-easy shiro-vpn-node deploy/wg-easy 51821 18087 yes
xui shiro-vpn-node svc/xui 2053 18089 yes
dbgate shiro svc/dbgate 3000 18088 yes
EOF
}

forward_stop() {
  sudo -v
  for pid_file in "$FORWARD_DIR"/*.pid; do
    [ -e "$pid_file" ] || continue
    forward_stop_one "$(basename "$pid_file" .pid)"
  done
}

port_listening() {
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"
}

forward_stop_one() {
  name=$1
  : >"$FORWARD_DIR/$name.stop"
  [ -f "$FORWARD_DIR/$name.child" ] &&
    sudo kill "$(cat "$FORWARD_DIR/$name.child")" 2>/dev/null || true
  sudo kill "$(cat "$FORWARD_DIR/$name.pid")" 2>/dev/null || true
  rm -f "$FORWARD_DIR/$name.pid" "$FORWARD_DIR/$name.child" \
    "$FORWARD_DIR/$name.stop"
  echo "stopped $name"
}

forward_supervise() {
  name=$1 namespace=$2 target=$3 port=$4 local_port=$5
  log="$FORWARD_DIR/$name.log"
  stop_file="$FORWARD_DIR/$name.stop"
  pid_file="$FORWARD_DIR/$name.pid"
  rm -f "$stop_file"

  (
    echo "$BASHPID" >"$pid_file"
    delay=2
    while [ ! -e "$stop_file" ] &&
      [ "$(cat "$pid_file" 2>/dev/null)" = "$BASHPID" ]; do
      sudo k3s kubectl -n "$namespace" port-forward "$target" \
        "$local_port:$port" --address "$FORWARD_ADDRESS" >>"$log" 2>&1 &
      child=$!
      echo "$child" >"$FORWARD_DIR/$name.child"
      started=$(date +%s)
      wait "$child" || true
      [ -e "$stop_file" ] && break

      if [ $(($(date +%s) - started)) -ge 30 ]; then
        delay=2
      else
        delay=$((delay * 2))
        [ "$delay" -gt 60 ] && delay=60
      fi
      echo "$(date -Is) forward exited, reconnecting in ${delay}s" >>"$log"
      sleep "$delay"
    done
  ) &
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

  sudo -v

  while read -r name namespace target port local_port _; do
    [ -n "$name" ] || continue
    pid_file="$FORWARD_DIR/$name.pid"
    if [ -f "$pid_file" ] && sudo kill -0 "$(cat "$pid_file")" 2>/dev/null &&
      port_listening "$local_port"; then
      echo "$name is already forwarded on $local_port"
      continue
    fi
    [ -f "$pid_file" ] && forward_stop_one "$name"

    forward_supervise "$name" "$namespace" "$target" "$port" "$local_port"
    echo "$name -> http://$FORWARD_ADDRESS:$local_port"
  done <<<"$resolved"
}

full_image() {
  case $1 in
  */*) registry=${1%%/*} ;;
  *)
    echo "docker.io/library/$1"
    return
    ;;
  esac
  case $registry in
  *.* | *:* | localhost) echo "$1" ;;
  *) echo "docker.io/$1" ;;
  esac
}

cache_images() {
  images=$(
    for dir in manifests/core manifests/vpn_node manifests/observability; do
      kubectl kustomize "$dir"
    done | sed -n 's/^ *image: *//p' | grep -v '^ghcr.io/shirovpn/' | sort -u
  )

  failed=""
  for image in $images; do
    full=$(full_image "$image")
    if sudo k3s ctr -n k8s.io images ls -q | grep -qx "$full"; then
      echo "cached $image"
      continue
    fi
    echo "pulling $image"
    if sudo k3s ctr -n k8s.io images pull "$full" >/dev/null; then
      echo "ok $image"
    else
      echo "FAILED $image"
      failed="$failed $image"
    fi
  done

  if [ -n "$failed" ]; then
    echo
    echo "could not pull:$failed"
    echo "check DNS and egress on the node, then run this again"
    exit 1
  fi
}

image_platform() {
  case $(uname -m) in
  x86_64) echo linux/amd64 ;;
  aarch64 | arm64) echo linux/arm64 ;;
  *) echo "linux/$(uname -m)" ;;
  esac
}

save_images() {
  sudo -v
  # shellcheck disable=SC2046
  sudo k3s ctr -n k8s.io images export \
    --platform "$(image_platform)" "$IMAGE_CACHE" \
    $(sudo k3s ctr -n k8s.io images ls -q | grep -v '^sha256:' | sort -u)
  echo "wrote $IMAGE_CACHE ($(du -h "$IMAGE_CACHE" | cut -f1))"
}

load_images() {
  if [ ! -f "$IMAGE_CACHE" ]; then
    echo "no image cache at $IMAGE_CACHE, set IMAGE_CACHE to another path"
    exit 1
  fi
  sudo k3s ctr -n k8s.io images import \
    --platform "$(image_platform)" "$IMAGE_CACHE"
}

case "${1:-}" in
init_cluster) init_cluster ;;
join_cluster) join_cluster "${3:?usage: $0 join_cluster --profile <name>}" ;;
label) label "${3:?usage: $0 label --profile <name>}" ;;
run)
  shift
  env=""
  while [ $# -gt 0 ]; do
    case $1 in
    --env) env=${2:?--env needs dev or prod}; shift 2 ;;
    *)
      echo "unknown argument: $1"
      exit 1
      ;;
    esac
  done
  if [ -z "$env" ]; then
    echo "usage: $0 run --env dev|prod"
    exit 1
  fi
  run "$env"
  ;;
cache_images) cache_images ;;
save_images) save_images ;;
load_images) load_images ;;
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
  run --env <dev|prod>               create the Applications for this
                                     environment from
                                     argocd/applicationset-<env>.yaml
  cache_images                       pull third-party images into containerd
  save_images                        export every image to $IMAGE_CACHE
  load_images                        import them back after a reinstall
  forward [--all] [panel...]         port-forward panels, default is the ones
                                     with a password; reconnects by itself
  forward stop                       stop every forward

  FORWARD_ADDRESS=<ip>               address the forwards listen on, default
                                     127.0.0.1; set the Tailscale IP to reach
                                     the panels over Tailscale
EOF
  exit 1
  ;;
esac
