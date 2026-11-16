# k8s-new

Requirements for code in this repo, not a description of how it grew.

## Code requirements

### Comments

`deploy.sh`, `scripts/*.sh`, manifests, overlays and `argocd/*.yaml` carry no
comments: only the shebang and tool directives such as
`# shellcheck disable=SC2046`. A fact the code cannot express goes to
`README.md` or here.

### deploy.sh

- Install k3s only when both `/usr/local/bin/k3s` and
  `/etc/systemd/system/k3s.service` are missing: `k3s-uninstall.sh` removes the
  unit and `/var/lib/rancher/k3s` but can leave the binary behind, and a bare
  `command -v k3s` would then skip the installer and fail on `systemctl enable`.
- Keep the image cache outside `/var/lib/rancher` (default
  `/var/lib/shiro-k8s-images.tar`): a reinstall wipes containerd, so images are
  exported before `k3s-uninstall.sh` and imported back in seconds, while
  rebuilding dev images takes minutes.
- `init_cluster` sets `vm.max_map_count=262144`: elasticsearch mmaps its indices
  and refuses to start below that.
- Keep Argo CD `timeout.reconciliation` at `60s`: the `dev` branch relies on it
  to pick a push up without pressing Sync.
- `run` prints the checkout's branch next to the `targetRevision` it is about to
  apply, because Argo CD follows the pushed commit, not the working tree.
- `cache_images` skips `ghcr.io/shirovpn/*`: the dev images are built on the
  node and never pulled from a registry.
- `forward_targets` is a table of `name namespace target container-port
  local-port password`; `password=no` marks a panel with no login of its own,
  and those come up only with `--all`.
- Give every panel one supervisor: `kubectl port-forward` exits when its pod is
  replaced by any rollout or by a Sync with a new tag, and the supervisor
  reconnects. A tunnel that lived 30 seconds or more failed on a rollout and
  retries in 2s; one that dies immediately is a config error (wrong port,
  missing Service) and backs off up to 60s.
- The supervisor writes its own pid file and stops once a newer one takes it
  over, otherwise a replaced supervisor races it for the same local port. A
  panel counts as running only when the supervisor process is alive and the
  local port is listening — a live supervisor keeps looping while the tunnel
  itself fails.
- Forwards start in the background and cannot answer a prompt, so `sudo -v`
  runs before any of them starts and every panel name is resolved first: a typo
  must cost an error, not a password prompt. `forward stop` kills processes and
  needs the same fresh sudo ticket, otherwise the loop keeps reconnecting.

### v2raya and pod egress

- Three v2raya settings decide whether pods leave through the proxy: `veth*`
  absent from Settings → Excluded Interface Prefixes, the implementation
  `redirect`, and Port Sharing on. Port Sharing is the one that moves the
  transparent sink off `127.0.0.1:52345` to `*:52345`.
- Why the sink must not stay on loopback: `redirect` rewrites a forwarded SYN to
  the incoming interface's address, which for a pod is `cni0`
  (`10.42.0.1:52345`); a loopback-only listener answers `RST` and the pod sees a
  refused or timed-out connect. That is also why `route_localnet` does not help
  here — no loopback destination is involved once Port Sharing is on.
- Keep IP Forward on. `tproxy` was tried and left the pod's SYN timing out; do
  not switch to it without reading `ip rule` and the local route table first.
- Port Sharing exposes `20170–20172` and `52345` to the LAN and the tailnet
  without authentication; that is fine for one's own PC and wrong anywhere else.

### scripts/shiro-k8s-netfilter.sh

- One root run from the repo sets the host up from scratch: installs itself to
  `/usr/local/sbin/shiro-k8s-netfilter.sh`, writes and starts
  `shiro-k8s-netfilter.service`, rebuilds `table inet shiro_k8s` (v2raya's
  bypass mark `0x80` on cluster CIDRs and on pod DNS), writes
  `/etc/resolv.k8s.conf` with the default gateway plus the
  `kubelet-arg: resolv-conf` line in `/etc/rancher/k3s/config.yaml`, and finally
  checks the v2raya settings above, printing which one is wrong.
- Run from the installed path (the unit's `ExecStart`) it only rebuilds the
  table, so re-running the repo copy after editing the rules updates the host.
- The CoreDNS half is needed because the host `resolv.conf` is `127.0.0.1`
  (v2raya's own DNS): k3s copies it into CoreDNS, which then resolves nothing.
  k3s reads `config.yaml` at start, so with a running cluster the script asks
  for `systemctl restart k3s` instead of doing it.
- If `config.yaml` already carries a `kubelet-arg` block without `resolv-conf`,
  the script refuses to append a second key and asks for the line by hand.

