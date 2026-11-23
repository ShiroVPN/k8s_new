#!/bin/bash

FORWARD_DIR=${TMPDIR:-/tmp}/shiro-forward

forward_targets() {
  cat <<EOF
argocd argocd svc/argocd-server 443 18080 yes
grafana observability svc/grafana 3000 18081 yes
jaeger observability svc/jaeger 16686 18082 no
prometheus observability svc/prometheus 9090 18083 no
elasticsearch observability svc/elasticsearch 9200 18084 no
rabbitmq shiro svc/rabbitmq 15672 18085 yes
pgadmin shiro svc/pgadmin 80 18086 yes
dbgate shiro svc/dbgate 3000 18088 yes
EOF
  local record name index=0
  shopt -s nullglob
  for record in vpn-nodes/*.env; do
    name=$(basename "$record" .env)
    printf 'xui-%s shiro-vpn-%s svc/xui 2053 %s yes\n' \
      "$name" "$name" "$((18089 + index))"
    index=$((index + 1))
  done
  shopt -u nullglob
}

port_listening() {
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"
}

forward_stop_one() {
  local name=$1
  : >"$FORWARD_DIR/$name.stop"
  [ -f "$FORWARD_DIR/$name.child" ] &&
    sudo kill "$(cat "$FORWARD_DIR/$name.child")" 2>/dev/null || true
  sudo kill "$(cat "$FORWARD_DIR/$name.pid")" 2>/dev/null || true
  rm -f "$FORWARD_DIR/$name.pid" "$FORWARD_DIR/$name.child" \
    "$FORWARD_DIR/$name.stop"
  echo "stopped $name"
}

forward_stop() {
  local pid_file
  sudo -v
  for pid_file in "$FORWARD_DIR"/*.pid; do
    [ -e "$pid_file" ] || continue
    forward_stop_one "$(basename "$pid_file" .pid)"
  done
}

forward_supervise() {
  local name=$1 namespace=$2 target=$3 port=$4 local_port=$5 address=$6
  local log="$FORWARD_DIR/$name.log"
  local stop_file pid_file delay child started
  stop_file="$FORWARD_DIR/$name.stop"
  pid_file="$FORWARD_DIR/$name.pid"
  rm -f "$stop_file"

  (
    echo "$BASHPID" >"$pid_file"
    delay=2
    while [ ! -e "$stop_file" ] &&
      [ "$(cat "$pid_file" 2>/dev/null)" = "$BASHPID" ]; do
      sudo k3s kubectl -n "$namespace" port-forward "$target" \
        "$local_port:$port" --address "$address" >>"$log" 2>&1 &
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

forward_default_address() {
  local address
  address=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  if [ -n "$address" ] && ip -4 -o addr show | grep -q "inet $address/"; then
    echo "$address"
  else
    echo 127.0.0.1
  fi
}

forward_start() {
  local all=no targets name line resolved pid_file
  local address=${FORWARD_ADDRESS:-} default_address
  mkdir -p "$FORWARD_DIR"

  while [ "${1:-}" = --all ]; do
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

  if [ -z "$address" ]; then
    default_address=$(forward_default_address)
    printf 'FORWARD_ADDRESS [%s]: ' "$default_address"
    read -r address || true
    address=${address:-$default_address}
  fi

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

    forward_supervise "$name" "$namespace" "$target" "$port" "$local_port" \
      "$address"
    echo "$name -> http://$address:$local_port"
  done <<<"$resolved"
}

forward() {
  if [ "${1:-}" = stop ]; then
    forward_stop
    return
  fi
  forward_start "$@"
}
