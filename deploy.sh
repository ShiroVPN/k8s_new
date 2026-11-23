#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

source scripts/common.sh
source scripts/images.sh
source scripts/init_cluster.sh
source scripts/join_cluster.sh
source scripts/run.sh
source scripts/forward.sh

usage() {
  cat <<EOF
usage: $0 <command>

  init_cluster                       install k3s, Argo CD and KSOPS
  join_cluster                       join an existing cluster; reads K3S_URL,
                                     K3S_TOKEN and DEPLOY_KUBECONFIG_B64
  run --env <dev|prod> --apps <list> create or update Applications for the
                                     named apps; vpn-node reads this machine's
                                     record in vpn-nodes/
  cache_images                       pull third-party images into containerd
  save_images                        export every image to $IMAGE_CACHE
  load_images                        import them back after a reinstall
  forward [--all] [panel...]         port-forward panels; a vpn panel is named
                                     xui-<name>
  forward stop                       stop every forward

  FORWARD_ADDRESS=<ip>               address the forwards listen on; forward
                                     asks for it, default is the Tailscale IP
                                     while tailscale is up, else 127.0.0.1
  IMAGE_CACHE=<path>                 file save_images writes and load_images
                                     reads, default $IMAGE_CACHE
EOF
}

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

command=$1
shift

case $command in
init_cluster | join_cluster | run | cache_images | save_images | \
  load_images | forward)
  "$command" "$@"
  ;;
*)
  usage
  exit 1
  ;;
esac
