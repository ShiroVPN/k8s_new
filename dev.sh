#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

ROOT=$(pwd)
BRANCH=dev
COMPONENT=overlays/dev/component/kustomization.yaml
ENGINE=${CONTAINER_ENGINE:-docker}

source_dir() {
  case $1 in
  main-api-worker) echo "${MAIN_API_WORKER_DIR:-$ROOT/../main_api_worker}" ;;
  bot) echo "${BOT_DIR:-$ROOT/../BotV2}" ;;
  peerhub-wireguard-worker)
    echo "${WG_WORKER_DIR:-$ROOT/../peerhub_wireguard_worker}"
    ;;
  *) return 1 ;;
  esac
}

image_name() {
  case $1 in
  main-api-worker) echo ghcr.io/shirovpn/main_api_worker ;;
  bot) echo ghcr.io/shirovpn/botv2 ;;
  peerhub-wireguard-worker) echo ghcr.io/shirovpn/peerhub_wireguard_worker ;;
  *) return 1 ;;
  esac
}

COMPONENTS="main-api-worker bot peerhub-wireguard-worker"

pull_sources() {
  for component in $COMPONENTS; do
    dir=$(source_dir "$component")
    if [ ! -d "$dir/.git" ]; then
      echo "$component: no git repository at $dir, skipped"
      continue
    fi
    git -C "$dir" pull --ff-only
  done
}

retag() {
  tag=$1
  shift
  python3 - "$COMPONENT" "$tag" "$@" <<'PY'
import re
import sys

path, tag, *images = sys.argv[1:]
text = open(path).read()
for image in images:
    pattern = rf"(- name: {re.escape(image)}\n\s+newTag: )[^\n]*"
    text, count = re.subn(pattern, rf"\g<1>{tag}", text)
    if count != 1:
        raise SystemExit(f"{image}: expected one newTag line, found {count}")
open(path, "w").write(text)
PY
}

build() {
  components=${*:-$COMPONENTS}
  tag=dev-$(date +%Y%m%d-%H%M%S)
  images=""

  for component in $components; do
    dir=$(source_dir "$component") || {
      echo "unknown component: $component"
      exit 1
    }
    image=$(image_name "$component")
    echo "building $image:$tag from $dir"
    "$ENGINE" build --tag "$image:$tag" "$dir"
    "$ENGINE" save "$image:$tag" | sudo k3s ctr -n k8s.io images import -
    images="$images $image"
  done

  # shellcheck disable=SC2086
  retag "$tag" $images
  echo "tags in $COMPONENT: $tag"

  git add "$COMPONENT"
  git commit -m "dev: rebuild ${components// /, } as $tag"
  git push origin "$BRANCH"
  echo "pushed, Argo CD picks it up within a minute"
}

case "${1:-}" in
build | pull)
  if [ "$(git branch --show-current)" != "$BRANCH" ]; then
    echo "run this on the $BRANCH branch"
    exit 1
  fi
  if [ "$1" = "pull" ]; then
    pull_sources
  else
    shift
    build "$@"
  fi
  ;;
*)
  echo "usage: $0 build [component...] | pull"
  echo "components: $COMPONENTS"
  echo "env: CONTAINER_ENGINE, MAIN_API_WORKER_DIR, BOT_DIR, WG_WORKER_DIR"
  exit 1
  ;;
esac
