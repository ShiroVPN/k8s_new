#!/bin/bash

revision=main

run_usage() {
  cat <<EOF
usage: ./deploy.sh run --env <dev|prod> --apps <app[,app...]>

  vpn-node  deploys this machine's vpn node. vpn-nodes/<name>.env is created
            on first use and holds SERVER, SERVER_NAME, SERVER_HOST, COUNTRY
            and the xui peerhub id
EOF
  exit 1
}

ask() {
  local value
  read -r -p "$1" value || {
    echo "no answer for $1" >&2
    exit 1
  }
  printf '%s' "$value"
}

overlay_namespace() {
  local namespace
  namespace=$(sed -n 's/^namespace: *//p' "overlays/$1/kustomization.yaml")
  [ -n "$namespace" ] || {
    echo "overlays/$1/kustomization.yaml has no namespace" >&2
    exit 1
  }
  printf '%s' "$namespace"
}

guard_applicationsets() {
  local sets
  sets=$(k -n argocd get applicationsets.argoproj.io -o name 2>/dev/null || true)
  [ -z "$sets" ] && return 0
  echo "these ApplicationSets still own Applications:" >&2
  printf '%s\n' "$sets" >&2
  echo "delete them first:" >&2
  echo "  sudo k3s kubectl -n argocd delete applicationset --all" >&2
  echo "their Applications and PVCs are pruned by the finalizer" >&2
  exit 1
}

guard_node() {
  local name=$1 node=$2 current
  current=$(k -n argocd get application "$name" \
    -o jsonpath='{.metadata.labels.shiro-node}' 2>/dev/null || true)
  if [ -z "$current" ] || [ "$current" = "$node" ]; then
    return 0
  fi
  echo "application $name is pinned to node $current" >&2
  echo "delete it first if it must move to $node" >&2
  exit 1
}

print_application() {
  local name=$1 path=$2 namespace=$3 env=$4 node=$5 extra=${6:-}
  cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $name
  namespace: argocd
  labels:
    shiro-node: "$node"
    shiro-env: "$env"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/ShiroVPN/k8s_new.git
    targetRevision: $revision
    path: $path
    kustomize:
      components:
        - ../../components/$env
      patches:
        - target:
            kind: Deployment
          patch: |-
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: ignored
            spec:
              template:
                spec:
                  nodeSelector:
                    kubernetes.io/hostname: "$node"
EOF
  if [ -n "$extra" ]; then
    printf '%s\n' "$extra"
  fi
  cat <<EOF
  destination:
    server: https://kubernetes.default.svc
    namespace: $namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PruneLast=true
      - PrunePropagationPolicy=foreground
EOF
}

apply_app() {
  local env=$1 app=$2 node=$3 namespace
  namespace=$(overlay_namespace "$app")
  guard_node "$app" "$node"
  print_application "$app" "overlays/$app" "$namespace" "$env" "$node" |
    k apply -f -
}

find_vpn_record() {
  local server=$1 path found=""
  shopt -s nullglob
  for path in vpn-nodes/*.env; do
    if grep -qx "SERVER=$server" "$path"; then
      [ -z "$found" ] || {
        echo "two records claim SERVER=$server: $found $path" >&2
        exit 1
      }
      found=$path
    fi
  done
  shopt -u nullglob
  printf '%s' "$found"
}

create_vpn_record() {
  local server=$1 name host country xui_id
  local default_xui path
  name=$(ask "SERVER_NAME (app suffix, for example de): ")
  [[ $name =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#name} -le 40 ]] || {
    echo "SERVER_NAME must be a DNS label of at most 40 characters" >&2
    exit 1
  }
  host=$(ask "SERVER_HOST (public DNS name of $server): ")
  [[ $host =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || {
    echo "SERVER_HOST must be a DNS name" >&2
    exit 1
  }
  country=$(ask "COUNTRY [DE]: ")
  country=${country:-DE}
  [[ $country =~ ^[A-Za-z]+$ ]] || {
    echo "COUNTRY must be letters only" >&2
    exit 1
  }
  default_xui=$(cat /proc/sys/kernel/random/uuid)
  xui_id=$(ask "XUI_PEERHUB_ID [$default_xui]: ")

  path="vpn-nodes/$name.env"
  mkdir -p vpn-nodes
  {
    echo "SERVER=$server"
    echo "SERVER_NAME=$name"
    echo "SERVER_HOST=$host"
    echo "COUNTRY=$country"
    echo "XUI_PEERHUB_ID=${xui_id:-$default_xui}"
    echo "XUI_VLESS_PORT=22531"
    echo "XUI_AWG_PORT=51830"
    echo "XUI_INBOUND_IDS=[]"
    echo "XUI_VERIFY=true"
  } >"$path"
  echo "wrote $path" >&2
  echo "  git add $path" >&2
  echo "  git commit -m \"vpn-nodes: add $name\"" >&2
  printf '%s' "$path"
}

read_vpn_record() {
  local path=$1 key
  for key in SERVER SERVER_NAME SERVER_HOST COUNTRY XUI_PEERHUB_ID \
    XUI_VLESS_PORT XUI_AWG_PORT XUI_INBOUND_IDS XUI_VERIFY; do
    grep -qE "^$key=" "$path" || {
      echo "$path has no $key" >&2
      exit 1
    }
  done
  (
    set -a
    # shellcheck disable=SC1090
    source "$path"
    set +a
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$SERVER" "$SERVER_NAME" "$SERVER_HOST" "$COUNTRY" "$XUI_PEERHUB_ID" \
      "$XUI_VLESS_PORT" "$XUI_AWG_PORT" "$XUI_INBOUND_IDS" "$XUI_VERIFY"
  )
}

validate_vpn_record() {
  local path=$1 line=$2
  local server server_name server_host country xui_id
  local vless_port awg_port inbound_ids verify uuid_re
  IFS='|' read -r server server_name server_host country xui_id \
    vless_port awg_port inbound_ids verify <<<"$line"
  uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  [ "$(basename "$path" .env)" = "$server_name" ] || {
    echo "$path must be named $server_name.env" >&2
    exit 1
  }
  [[ $server_name =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#server_name} -le 40 ]] || {
    echo "SERVER_NAME must be a DNS label of at most 40 characters" >&2
    exit 1
  }
  [[ $server_host =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || {
    echo "SERVER_HOST must be a DNS name" >&2
    exit 1
  }
  [[ $country =~ ^[A-Za-z]+$ ]] || {
    echo "COUNTRY must be letters only" >&2
    exit 1
  }
  [[ $xui_id =~ $uuid_re ]] || {
    echo "XUI_PEERHUB_ID must be a uuid" >&2
    exit 1
  }
  [[ $vless_port =~ ^[0-9]+$ && $awg_port =~ ^[0-9]+$ ]] || {
    echo "ports must be numbers" >&2
    exit 1
  }
  [[ $inbound_ids =~ ^\[[0-9,]*\]$ ]] || {
    echo "XUI_INBOUND_IDS must look like [] or [1,2]" >&2
    exit 1
  }
  [ "$verify" = true ] || [ "$verify" = false ] || {
    echo "XUI_VERIFY must be true or false" >&2
    exit 1
  }
}

apply_vpn_node() {
  local env=$1 node=$2 record values app namespace
  local server server_name server_host country xui_id
  local vless_port awg_port inbound_ids verify config_hash extra

  record=$(find_vpn_record "$node")
  if [ -z "$record" ]; then
    record=$(create_vpn_record "$node")
  fi

  values=$(read_vpn_record "$record")
  validate_vpn_record "$record" "$values"
  IFS='|' read -r server server_name server_host country xui_id \
    vless_port awg_port inbound_ids verify <<<"$values"

  k get node "$server" -o name >/dev/null || {
    echo "node $server is not in the cluster; join it first" >&2
    exit 1
  }

  app="$env-vpn-node-$server_name"
  namespace="shiro-vpn-$server_name"
  config_hash=$(printf '%s\n' "$server" "$server_name" "$server_host" \
    "$country" "$xui_id" "$vless_port" "$awg_port" \
    "$inbound_ids" "$verify" | sha256sum | cut -c1-16)

  extra=$(cat <<EOF
        - target:
            kind: ConfigMap
            name: vpn-node-config
          patch: |-
            - op: add
              path: /data
              value:
                SERVER_NAME: "$server_name"
                SERVER_HOST: "$server_host"
                COUNTRY: "$country"
                XUI_VLESS_PORT: "$vless_port"
                XUI_AWG_PORT: "$awg_port"
                XUI_INBOUND_IDS: "$inbound_ids"
                XUI_VERIFY: "$verify"
                XUI_PEERHUB_ID: "$xui_id"
        - target:
            kind: Deployment
          patch: |-
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: ignored
            spec:
              template:
                metadata:
                  annotations:
                    shiro.io/config-hash: "$config_hash"
EOF
)

  guard_node "$app" "$server"
  print_application "$app" overlays/vpn-node "$namespace" "$env" "$server" \
    "$extra" | k apply -f -
  echo "vpn node $server_name on $server: application $app, namespace $namespace"
}

run() {
  local env="" apps="" app node
  local -a app_list=()

  while [ $# -gt 0 ]; do
    case $1 in
    --env) env=${2:?--env needs dev or prod}; shift 2 ;;
    --apps) apps=${2:?--apps needs a list}; shift 2 ;;
    *) echo "unknown argument: $1"; run_usage ;;
    esac
  done
  [ -n "$env" ] && [ -n "$apps" ] || run_usage
  [ -d "components/$env" ] || {
    echo "no such environment: $env"
    exit 1
  }

  guard_applicationsets
  node=$(node_name)
  k get node "$node" -o name >/dev/null || {
    echo "node $node is not in the cluster; run this on a joined node" >&2
    exit 1
  }
  echo "apps '$apps' for env $env on node $node (targetRevision: $revision)"

  IFS=, read -ra app_list <<<"$apps"
  for app in "${app_list[@]}"; do
    if [ "$app" = vpn-node ]; then
      apply_vpn_node "$env" "$node"
    else
      [ -d "overlays/$app" ] || {
        echo "no such app: $app"
        exit 1
      }
      apply_app "$env" "$app" "$node"
    fi
  done

  k -n argocd get applications
}
