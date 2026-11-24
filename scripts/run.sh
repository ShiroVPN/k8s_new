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
EOF
  if [ "$name" = "$env-core" ]; then
    printf '        - ../../components/%s-secrets\n' "$env"
  fi
  cat <<EOF
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
  local env=$1 app=$2 node=$3 namespace name
  namespace=$(overlay_namespace "$app")
  name="$env-$app"
  guard_node "$name" "$node"
  print_application "$name" "overlays/$app" "$namespace" "$env" "$node" |
    k apply -f -
}

find_vpn_record() {
  local server=$1 env=$2 path found=""
  shopt -s nullglob
  for path in vpn-nodes/*.env; do
    grep -qx "SERVER=$server" "$path" || continue
    grep -q "^ENV=" "$path" || {
      echo "$path has no ENV; add ENV=dev or ENV=prod" >&2
      exit 1
    }
    if grep -qx "ENV=$env" "$path"; then
      [ -z "$found" ] || {
        echo "two records claim SERVER=$server and ENV=$env: $found $path" >&2
        exit 1
      }
      found=$path
    fi
  done
  shopt -u nullglob
  printf '%s' "$found"
}

create_vpn_record() {
  local env=$1 server=$2 name host country xui_id vless_port awg_port caddy
  local default_xui path
  name=$(ask "SERVER_NAME (app suffix, for example de): ")
  [[ $name =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#name} -le 40 ]] || {
    echo "SERVER_NAME must be a DNS label of at most 40 characters" >&2
    exit 1
  }
  path="vpn-nodes/$name.$env.env"
  [ -e "$path" ] && {
    echo "$path already exists; choose another SERVER_NAME" >&2
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
  vless_port=$(ask "XUI_VLESS_PORT [22531]: ")
  vless_port=${vless_port:-22531}
  awg_port=$(ask "XUI_AWG_PORT [51830]: ")
  awg_port=${awg_port:-51830}
  [[ $vless_port =~ ^[0-9]+$ && $awg_port =~ ^[0-9]+$ ]] || {
    echo "ports must be numbers" >&2
    exit 1
  }
  caddy=$(ask "CADDY [on]: ")
  caddy=${caddy:-on}
  [ "$caddy" = on ] || [ "$caddy" = off ] || {
    echo "CADDY must be on or off" >&2
    exit 1
  }
  default_xui=$(cat /proc/sys/kernel/random/uuid)
  xui_id=$(ask "XUI_PEERHUB_ID [$default_xui]: ")

  mkdir -p vpn-nodes
  {
    echo "SERVER=$server"
    echo "ENV=$env"
    echo "SERVER_NAME=$name"
    echo "SERVER_HOST=$host"
    echo "COUNTRY=$country"
    echo "XUI_PEERHUB_ID=${xui_id:-$default_xui}"
    echo "XUI_VLESS_PORT=$vless_port"
    echo "XUI_AWG_PORT=$awg_port"
    echo "XUI_INBOUND_IDS=[]"
    echo "XUI_VERIFY=true"
    echo "CADDY=$caddy"
  } >"$path"
  echo "wrote $path" >&2
  echo "  git add $path" >&2
  echo "  git commit -m \"vpn-nodes: add $name\"" >&2
  printf '%s' "$path"
}

read_vpn_record() {
  local path=$1 key
  for key in SERVER ENV SERVER_NAME SERVER_HOST COUNTRY XUI_PEERHUB_ID \
    XUI_VLESS_PORT XUI_AWG_PORT XUI_INBOUND_IDS XUI_VERIFY CADDY; do
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
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$SERVER" "$ENV" "$SERVER_NAME" "$SERVER_HOST" "$COUNTRY" \
      "$XUI_PEERHUB_ID" "$XUI_VLESS_PORT" "$XUI_AWG_PORT" \
      "$XUI_INBOUND_IDS" "$XUI_VERIFY" "$CADDY"
  )
}

validate_vpn_record() {
  local path=$1 line=$2
  local server record_env server_name server_host country xui_id
  local vless_port awg_port inbound_ids verify caddy uuid_re
  IFS='|' read -r server record_env server_name server_host country xui_id \
    vless_port awg_port inbound_ids verify caddy <<<"$line"
  uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  [ "$record_env" = dev ] || [ "$record_env" = prod ] || {
    echo "$path ENV must be dev or prod" >&2
    exit 1
  }
  [ "$(basename "$path" .env)" = "$server_name.$record_env" ] || {
    echo "$path must be named $server_name.$record_env.env" >&2
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
  [ "$caddy" = on ] || [ "$caddy" = off ] || {
    echo "CADDY must be on or off" >&2
    exit 1
  }
}

guard_server_ports() {
  local current=$1 server=$2 vless=$3 awg=$4 caddy=$5 line path
  local other_server other_vless other_awg other_caddy
  shopt -s nullglob
  for path in vpn-nodes/*.env; do
    [ "$path" = "$current" ] && continue
    line=$(read_vpn_record "$path")
    IFS='|' read -r other_server _ _ _ _ _ other_vless other_awg \
      _ _ other_caddy <<<"$line"
    [ "$other_server" = "$server" ] || continue
    if [ "$other_vless" = "$vless" ] || [ "$other_awg" = "$awg" ]; then
      echo "$path holds $other_vless/tcp and $other_awg/udp on $server" >&2
      echo "give this record other ports" >&2
      exit 1
    fi
    if [ "$caddy" = on ] && [ "$other_caddy" = on ]; then
      echo "$path already serves 80/443 on $server" >&2
      echo "only one record per server runs caddy; set CADDY=off" >&2
      exit 1
    fi
  done
  shopt -u nullglob
}

apply_vpn_node() {
  local env=$1 node=$2 record values app namespace
  local server server_name server_host country xui_id
  local vless_port awg_port inbound_ids verify config_hash extra

  record=$(find_vpn_record "$node" "$env")
  if [ -z "$record" ]; then
    record=$(create_vpn_record "$env" "$node")
    [ -n "$record" ] || exit 1
  fi

  values=$(read_vpn_record "$record")
  validate_vpn_record "$record" "$values"
  IFS='|' read -r server _ server_name server_host country xui_id \
    vless_port awg_port inbound_ids verify caddy <<<"$values"

  guard_server_ports "$record" "$server" "$vless_port" "$awg_port" "$caddy"

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
            name: xui
          patch: |-
            - op: test
              path: /spec/template/spec/containers/0/name
              value: xui
            - op: replace
              path: /spec/template/spec/containers/0/ports
              value:
                - name: panel
                  containerPort: 2053
                - name: subscription
                  containerPort: 2096
                  protocol: TCP
                - name: inbound-awg
                  containerPort: $awg_port
                  hostPort: $awg_port
                  protocol: UDP
                - name: inbound-vless
                  containerPort: $vless_port
                  hostPort: $vless_port
                  protocol: TCP
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

  if [ "$caddy" = off ]; then
    extra+=$(cat <<EOF

        - target:
            kind: Deployment
            name: caddy
          patch: |-
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: caddy
            spec:
              replicas: 0
EOF
)
  fi

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
