#!/bin/bash

ARGOCD_VERSION=v3.6.1

k3s_installed() {
  [ -x /usr/local/bin/k3s ] && [ -f /etc/systemd/system/k3s.service ]
}

init_cluster() {
  local node key ip token password deploy_token ca kubeconfig kubeconfig_b64
  local resolv=/etc/resolv.k8s.conf tailnet

  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' |
    sudo tee "$resolv" >/dev/null
  tailnet=$(tailscale ip -4 2>/dev/null | head -n1 || true)

  if ! k3s_installed; then
    sudo mkdir -p /etc/rancher/k3s
    {
      if [ -n "$tailnet" ]; then
        printf 'node-ip: %s\nflannel-iface: tailscale0\n' "$tailnet"
      fi
      printf 'kubelet-arg:\n  - "resolv-conf=%s"\n' "$resolv"
    } | sudo tee /etc/rancher/k3s/config.yaml >/dev/null
    curl -sfL https://get.k3s.io |
      INSTALL_K3S_VERSION="$K3S_VERSION" \
      INSTALL_K3S_EXEC="server --disable=traefik --disable=servicelb" sh -
  fi
  sudo systemctl enable --now k3s
  node=$(node_name)
  k_admin wait --for=create node/"$node" --timeout=120s
  k_admin wait --for=condition=Ready node/"$node" --timeout=120s

  sudo sysctl -w vm.max_map_count=262144 >/dev/null

  k_admin create namespace shiro --dry-run=client -o yaml | k_admin apply -f -
  k_admin create namespace argocd --dry-run=client -o yaml | k_admin apply -f -
  k_admin apply --server-side -n argocd -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
  k_admin -n argocd rollout status deploy/argocd-server --timeout=300s
  k_admin -n argocd patch configmap argocd-cm --type merge \
    -p '{"data":{"kustomize.buildOptions":"--enable-alpha-plugins --enable-exec","timeout.reconciliation":"60s"}}'

  key=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
  if [ ! -f "$key" ]; then
    echo "sops age key not found: $key"
    echo "put the private key there or set SOPS_AGE_KEY_FILE, then re-run ./deploy.sh init_cluster"
    exit 1
  fi
  k_admin -n argocd create secret generic sops-age \
    --from-file=keys.txt="$key" --dry-run=client -o yaml | k_admin apply -f -
  k_admin -n argocd patch deploy argocd-repo-server --patch-file argocd/ksops-patch.yaml
  k_admin -n argocd rollout status deploy/argocd-repo-server --timeout=300s

  ip=$(k_admin get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  [ -n "$ip" ] || {
    echo "no InternalIP on node $node" >&2
    exit 1
  }

  k_admin apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: deploy-runner
  namespace: argocd
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: deploy-runner
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["applications", "applicationsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: deploy-runner
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: deploy-runner
subjects:
  - kind: ServiceAccount
    name: deploy-runner
    namespace: argocd
---
apiVersion: v1
kind: Secret
metadata:
  name: deploy-runner-token
  namespace: argocd
  annotations:
    kubernetes.io/service-account.name: deploy-runner
type: kubernetes.io/service-account-token
EOF

  k_admin -n argocd wait --for=jsonpath='{.data.token}' \
    secret/deploy-runner-token --timeout=60s
  deploy_token=$(k_admin -n argocd get secret deploy-runner-token \
    -o jsonpath='{.data.token}' | base64 -d)
  [ -n "$deploy_token" ] || {
    echo "deploy-runner token is empty" >&2
    exit 1
  }
  ca=$(k_admin config view --raw --minify \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  [ -n "$ca" ] || {
    echo "the admin kubeconfig has no certificate-authority-data" >&2
    exit 1
  }

  kubeconfig=$(mktemp)
  chmod 600 "$kubeconfig"
  {
    echo "apiVersion: v1"
    echo "kind: Config"
    echo "clusters:"
    echo "  - name: shiro"
    echo "    cluster:"
    echo "      server: https://$ip:6443"
    echo "      certificate-authority-data: $ca"
    echo "users:"
    echo "  - name: deploy-runner"
    echo "    user:"
    echo "      token: $deploy_token"
    echo "contexts:"
    echo "  - name: shiro"
    echo "    context:"
    echo "      cluster: shiro"
    echo "      user: deploy-runner"
    echo "current-context: shiro"
  } >"$kubeconfig"
  sudo install -m 600 "$kubeconfig" "$DEPLOY_KUBECONFIG"
  rm -f "$kubeconfig"
  kubeconfig_b64=$(sudo base64 -w0 "$DEPLOY_KUBECONFIG")

  token=$(sudo cat /var/lib/rancher/k3s/server/node-token)
  password=$(k_admin -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

  cat <<EOF

Argo CD panel:
  ./deploy.sh forward argocd
  ssh -L 18080:127.0.0.1:18080 <this server>
  https://localhost:18080  admin
  password: ${password:-<argocd-initial-admin-secret not found>}

applications:
  ./deploy.sh run --env prod --apps core,observability,bot
  ./deploy.sh run --env dev --apps core,observability,bot

panels:
  ./deploy.sh forward          # all of them on 127.0.0.1:18081-18089
  ./deploy.sh forward stop

new VPN node:
  git clone https://github.com/ShiroVPN/k8s_new.git
  K3S_URL=https://$ip:6443 \\
  K3S_TOKEN=$token \\
  DEPLOY_KUBECONFIG_B64=$kubeconfig_b64 \\
  ./deploy.sh join_cluster
  then on that node: ./deploy.sh run --env prod --apps vpn-node
  ports 6443 to the core, 8472/udp and 10250/tcp both ways - see README
EOF
}
