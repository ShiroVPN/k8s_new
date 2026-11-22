#!/bin/bash

IMAGE_CACHE=${IMAGE_CACHE:-/var/lib/shiro-k8s-images.tar}

full_image() {
  local registry
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

image_platform() {
  case $(uname -m) in
  x86_64) echo linux/amd64 ;;
  aarch64 | arm64) echo linux/arm64 ;;
  *) echo "linux/$(uname -m)" ;;
  esac
}

progress() {
  local start=$SECONDS file=${1:-} line
  while :; do
    sleep 2
    line="$((SECONDS - start))s"
    if [ -n "$file" ] && [ -f "$file" ]; then
      line="$(du -h "$file" | cut -f1) written, $line"
    fi
    if [ -t 2 ]; then
      printf '\r  %s' "$line" >&2
    else
      echo "  $line" >&2
    fi
  done
}

with_progress() {
  local file=${1:-} reporter status=0
  shift
  progress "$file" &
  reporter=$!
  "$@" || status=$?
  kill "$reporter" 2>/dev/null || true
  wait "$reporter" 2>/dev/null || true
  if [ -t 2 ]; then printf '\r\033[K' >&2; fi
  return "$status"
}

cache_images() {
  local images image full total index failed start started
  images=$(
    for dir in manifests/core manifests/vpn_node manifests/observability; do
      kubectl kustomize "$dir"
    done | sed -n 's/^ *image: *//p' | grep -v '^ghcr.io/shirovpn/' | sort -u
  )

  total=$(echo "$images" | wc -l)
  index=0
  failed=""
  start=$SECONDS
  for image in $images; do
    index=$((index + 1))
    full=$(full_image "$image")
    if sudo k3s ctr -n k8s.io images ls -q | grep -qx "$full"; then
      echo "[$index/$total] cached $image"
      continue
    fi
    echo "[$index/$total] pulling $image"
    started=$SECONDS
    if sudo k3s ctr -n k8s.io images pull "$full"; then
      echo "[$index/$total] ok $image in $((SECONDS - started))s"
    else
      echo "[$index/$total] FAILED $image after $((SECONDS - started))s"
      failed="$failed $image"
    fi
  done

  if [ -n "$failed" ]; then
    echo
    echo "could not pull:$failed"
    echo "check DNS and egress on the node, then run this again"
    exit 1
  fi
  echo "$total images ready in $((SECONDS - start))s"
}

save_images() {
  local refs ready skipped ref start
  sudo -v
  refs=$(sudo k3s ctr -n k8s.io images ls -q | grep -v '^sha256:' | sort -u)
  ready=$(sudo k3s ctr -n k8s.io images check 2>/dev/null |
    awk '$4 == "complete" { print $1 }' | sort -u || true)
  [ -n "$ready" ] || {
    echo "ctr images check returned no complete refs" >&2
    exit 1
  }
  skipped=$(comm -23 <(printf '%s\n' "$refs") <(printf '%s\n' "$ready"))
  if [ -n "$skipped" ]; then
    echo "skipping refs with missing content:" >&2
    while read -r ref; do
      echo "  $ref" >&2
    done <<<"$skipped"
    refs=$(comm -12 <(printf '%s\n' "$refs") <(printf '%s\n' "$ready"))
  fi
  [ -n "$refs" ] || {
    echo "no complete images to export" >&2
    exit 1
  }
  echo "exporting $(echo "$refs" | wc -l) images to $IMAGE_CACHE"
  start=$SECONDS
  # shellcheck disable=SC2046
  with_progress "$IMAGE_CACHE" sudo k3s ctr -n k8s.io images export \
    --platform "$(image_platform)" "$IMAGE_CACHE" $refs
  echo "wrote $IMAGE_CACHE ($(du -h "$IMAGE_CACHE" | cut -f1)) in $((SECONDS - start))s"
}

load_images() {
  local start
  if [ ! -f "$IMAGE_CACHE" ]; then
    echo "no image cache at $IMAGE_CACHE, set IMAGE_CACHE to another path"
    exit 1
  fi

  echo "importing $IMAGE_CACHE ($(du -h "$IMAGE_CACHE" | cut -f1))"
  start=$SECONDS
  with_progress "" sudo k3s ctr -n k8s.io images import \
    --platform "$(image_platform)" "$IMAGE_CACHE"
  echo "imported in $((SECONDS - start))s"
}
