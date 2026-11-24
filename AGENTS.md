# k8s-new

Requirements for code and deployment in this repo, not a description of how it
grew.

## Code requirements

### Comments

`deploy.sh`, `scripts/*.sh`, manifests, overlays and `argocd/*.yaml` carry no
comments: only the shebang and tool directives such as
`# shellcheck disable=SC2046`. A fact the code cannot express goes to
`README.md` or here.

### Knobs

A value an operator changes is an environment variable with a default, not a
constant in the middle of a function: `IMAGE_CACHE`, `FORWARD_ADDRESS`,
`SOPS_AGE_KEY_FILE`, `DEPLOY_KUBECONFIG`. Validate a record before applying it
and exit on a bad value.

## Pipeline

- One env is one cluster. `--env` selects `components/<env>` for the image tags.
  It is not a branch.
- `init_cluster` on the first server. `join_cluster` on every other server.
  `run --env <env> --apps <list>` on the machine that must carry the apps.
- `run` creates the Applications. Never add an ApplicationSet: it owns its
  Applications and overwrites what `run` applies. `run` refuses to work while
  an ApplicationSet exists.
- `run` pins every Deployment with
  `nodeSelector: kubernetes.io/hostname=<node>` and labels the Application
  `shiro-node` and `shiro-env`. It refuses to retarget an Application that is
  pinned to another node. Delete the Application to move it.
- `core`, `bot` and `observability` exist once per env. `vpn-node` exists once
  per record.
- Every node needs the deploy kubeconfig. `init_cluster` creates the
  `deploy-runner` ServiceAccount, a ClusterRole for `applications` and
  `applicationsets` plus `nodes` get/list/watch, and a token Secret, then
  writes `/etc/rancher/k3s/shiro.kubeconfig`. `join_cluster` installs the copy
  from `DEPLOY_KUBECONFIG_B64`. `k` uses that file; every admin step in
  `init_cluster` uses `k_admin`.
- The token controller fills the Secret asynchronously. Wait for
  `{.data.token}` before reading it.
- `init_cluster` prints the join command with `K3S_URL`, `K3S_TOKEN` and
  `DEPLOY_KUBECONFIG_B64`. The `K3S_URL` must be the core's tailnet address.

## Node address

- The core must start on the tailnet address. Write `node-ip` and
  `flannel-iface: tailscale0` to `/etc/rancher/k3s/config.yaml` before the k3s
  install. Otherwise the agent joins and gets no pod network.
- Both server and agent need `kubelet-arg: "resolv-conf=/etc/resolv.k8s.conf"`.
  Go programs read `/etc/resolv.conf` directly, so MagicDNS breaks CoreDNS and
  image pulls while `getent` still works.
- `join_cluster` adds `--node-ip` from `tailscale ip -4`,
  `--flannel-iface=tailscale0` and the resolver flag, then waits for the node
  to become `Ready`.
- Check `ip -d link show flannel.1`: it must report `dev tailscale0`.
- After `init_cluster` run `scripts/shiro-k8s-vpn-fix.sh` on the core. It adds
  the ip rules for the PC's AmneziaWG tunnel and orders k3s after
  `tailscaled`.

## vpn node

- One record `vpn-nodes/<server_name>.env` per node. It holds `SERVER` (the k8s
  node name), `SERVER_NAME`, `SERVER_HOST`, `COUNTRY`, `XUI_PEERHUB_ID`,
  `XUI_VLESS_PORT`, `XUI_AWG_PORT`, `XUI_INBOUND_IDS` and `XUI_VERIFY`.
- `run --apps vpn-node` finds the record by `SERVER=$(hostname)`. When there is
  none, it asks for the values, writes the file and applies the Application
  `$env-vpn-node-$server_name` into `shiro-vpn-$server_name`. Commit the record;
  `run` and `forward` on other machines read this directory.
- One peerhub per node: the 3x-ui worker and its heartbeat. A peerhub has no
  Application of its own.
- Do not add a WireGuard peerhub back before `peerhub_wireguard_worker` moves to
  shiro v2.3.0. Its `peerhub.get_config` returns a bare string, while main_api
  validates `WgConfig | XuiConfig`, so every WireGuard peer fails to load a
  config.
- `overlays/vpn-node/vpn-node_config.yaml` is a tracked placeholder. Keep it in
  the kustomization and keep `.gitignore` from hiding any file the overlay
  references: a hidden file fails the whole `kustomize build` and the
  Application stays `Unknown`.
- Values come from the Application patch. `add /data` replaces the whole
  ConfigMap map, so the patch must carry every key the pods read. The patch also
  sets `shiro.io/config-hash` on the pod template; Argo rolls the pods when a
  record value changes. `run` must not restart pods itself.
- `vpn-node-config` holds `XUI_PEERHUB_ID`. The worker and the heartbeat keep
  the env name `PEERHUB_ID` and read the key through `configMapKeyRef.key`. Do
  not split the value into a second ConfigMap.
- The namespace comes from `spec.destination.namespace`. Do not set
  `kustomize.namespace` and do not put `namespace:` in the overlay.
- `hostPort` is node-wide. One vpn node per server.
- `2096/tcp` is in-cluster only: the `caddy` pod reaches the subscription
  through the `xui` Service and answers it on 443. A subscription link with
  `:2096` no longer answers from outside.
- All vpn nodes share `secrets/vpn-node.enc.yaml`. A per-node secret is a later
  change.

## Argo CD

- `argocd/ksops-patch.yaml` must keep `hostNetwork: false` explicitly. A field
  set by another field manager survives a patch that stops mentioning it. With
  `hostNetwork: true`, the repo-server's `8081` and `8084` are node ports, a
  `RollingUpdate` leaves the new pod `Pending`, and `init_cluster` dies at
  `rollout status` with `timed out waiting for the condition`.
- Keep `timeout.reconciliation` at `60s`: Argo follows the pushed commit.
- Keep the `sops-age` key in `argocd`; KSOPS decrypts the Secrets at sync.
- Deleting an Application with the finalizer prunes its resources. The PVCs go
  with it.

## Workarounds on the remote node

These exist because of the host, not because of a manifest mistake. Remove them
when the upstream or the host fixes the cause.

- A vpn node confines its containers: `kill -TERM` on its own child returns
  `EPERM` and `/proc/1/fd` is unreadable even as root, while the same image runs
  unconfined on `pc-omarchy`. `xui-db` therefore sets
  `securityContext.appArmorProfile: Unconfined`; without it `gosu` never
  returns, postgres never starts and the pod sits `0/1` with no log output.
- An interrupted first boot of `xui-db` leaves WAL from one cluster beside a
  `pg_control` from another, and every later start aborts with `could not locate
  a valid checkpoint record`. Delete the claim and let the entrypoint build a
  new directory; never pre-build one by hand.
- `xui` prepares the panel database, and Kubernetes does not order it after
  `xui-db`. The `wait-db` init container holds `configure` and `token` until
  postgres answers, so a database that is still starting cannot leave the panel
  without a schema.
- A PVC stuck `Terminating` keeps the Application `Progressing`, and with
  `PruneLast` the sync then never prunes anything. Delete the pod that mounts
  the claim; the finalizer releases at once.
- Caddy binds 80/443 on the remote node. duckdns does not hold them.

## deploy.sh

- Install k3s only when both `/usr/local/bin/k3s` and
  `/etc/systemd/system/k3s.service` are missing: `k3s-uninstall.sh` removes the
  unit and `/var/lib/rancher/k3s` but can leave the binary behind.
- Keep the image cache outside `/var/lib/rancher` (default
  `/var/lib/shiro-k8s-images.tar`): a reinstall wipes containerd.
- `save_images` exports only refs whose `ctr images check` status is
  `complete`. One tag with a missing blob aborts the whole export, so filter
  first, print the skipped refs and let the new cluster pull them.
- `init_cluster` sets `vm.max_map_count=262144`: elasticsearch needs it.
- `run` prints the checkout's branch next to the `targetRevision` it applies,
  because Argo follows the pushed commit, not the working tree.
- `cache_images` skips `ghcr.io/shirovpn/*`: the node builds those images and
  never pulls them from a registry.
- `forward` builds one entry per record: `xui-<name>` on the local port
  `18089 + i`. Panels marked `password=no` come up only with `--all`.
- Give every panel one supervisor: `kubectl port-forward` exits when its pod is
  replaced, and the supervisor reconnects. A tunnel that lived 30 seconds or
  more failed on a rollout and retries in 2s; one that dies immediately is a
  config error and backs off up to 60s.
- The supervisor writes its own pid file and stops once a newer one takes it
  over. A panel counts as running only when the supervisor is alive and the
  local port listens.
- Forwards start in the background and cannot answer a prompt, so `sudo -v`
  runs before any of them starts and every panel name is resolved first. A typo
  must cost an error, not a password prompt.

## Host requirements

- 6443/tcp between the core and the agents; 8472/udp and 10250/tcp both ways.
- 80/tcp and 443/tcp free where a vpn node runs caddy: the panel and the
  subscription link answer there.
- 22531/tcp and 51830/udp publish the VLESS and AmneziaWG inbounds through
  `hostPort`. A `hostPort` is DNAT, so ufw neither opens nor closes it.
- Pin `vm.max_map_count` in `/etc/sysctl.d/` for boots; `init_cluster` sets it
  for the first start.
- Disk: prometheus 2Gi, elasticsearch 5Gi, postgres 1Gi, rabbitmq 200Mi,
  xui 1Gi, xui-db 1Gi, caddy 100Mi, peerhub 100Mi.
- An A record for `SERVER_HOST` points at the node's public address.

## Panels

| Port | Panel | Login |
|---|---|---|
| 18080 | Argo CD | admin, password printed by `init_cluster` |
| 18081 | Grafana | admin, `GRAFANA_ADMIN_PASSWORD` from `observability-secret` |
| 18082 | Jaeger | none, only with `--all` |
| 18083 | Prometheus | none, only with `--all` |
| 18084 | Elasticsearch | none, only with `--all` |
| 18085 | RabbitMQ management | core, password from `shiro-secret` |
| 18086 | pgAdmin | admin@example.com, password from `shiro-secret` |
| 18088 | DbGate | admin, password from `shiro-secret` |
| 18089 + i | 3x-ui of a vpn node | from `node-secret` |

`i` is the record's position in `vpn-nodes/` sorted by name, starting at 0.

## CI and tests

- `.github/workflows/validate.yml` builds `manifests/core`, `manifests/bot`,
  `manifests/vpn_node` and `manifests/observability`. Overlays need the SOPS
  key, so CI does not build them.
- Test suites live in `ShiroVPN/shiro_tests`. This repo has no test Jobs.

## Reinstall

- Save images and dump Postgres before `k3s-uninstall.sh`: the uninstall
  removes the cluster and every PVC.
- Then `init_cluster`, `scripts/shiro-k8s-vpn-fix.sh`, `load_images`.
- Restore a dump into the new Postgres; the `migrate` init container builds the
  schema.

## Working rules

- Bash: safe commands (`cd`, `cat`, `ls`, `git status`, `git diff`) need no
  permission. Give a timeout to anything that may not finish.
- Git: stage, commit, push and tag only when asked. Otherwise print the
  commands. One short subject covers the whole change set; no body.
- Tests: read them. Change them only when asked.
- Docs: `README.md` is short and for humans. `AGENTS.md` is for agents and may
  grow. Do not edit `README.md` unless asked.
- A fact code cannot express goes to `README.md` or here, not into a comment.
- Write prose to about 80% of ASD-STE100: 20 words or fewer per sentence, one
  idea, active voice, imperative steps, concrete verbs, no idiom or hedge. Gloss
  a term STE lacks once.
- Refuse a half-good solution. State the limit instead.
