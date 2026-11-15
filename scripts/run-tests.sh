#!/bin/bash
# Run the suites of ShiroVPN/shiro_tests as Jobs inside the cluster.
#
# The image is built and published from shiro_tests; bump its tag in
# manifests/tests/*.yaml after a release.
set -euo pipefail

cd "$(dirname "$0")/.."

K=${KUBECTL:-kubectl}
CORE_NS=${CORE_NAMESPACE:-shiro}
NODE_NS=${NODE_NAMESPACE:-shiro-peerhub-wg}
TIMEOUT=${TESTS_TIMEOUT:-1800}

# main_api's heartbeat() marks a hub as alive and the tasks are routed to
# peerhub_queue.<id>: the suite must use the node's id, not a copy of it that
# can drift. Tests in the core namespace read it from this ConfigMap.
hub=$($K -n "$NODE_NS" get configmap peerhub-config \
  -o jsonpath='{.data.PEERHUB_ID}')
if [ -z "$hub" ]; then
  echo "no PEERHUB_ID in $NODE_NS/peerhub-config: is the node deployed?" >&2
  exit 1
fi
$K -n "$CORE_NS" create configmap tests-config \
  --from-literal=PEERHUB_ID="$hub" --dry-run=client -o yaml | $K apply -f -

# A finished Job never runs again and its spec is immutable: drop the old
# ones before applying the same names.
$K -n "$CORE_NS" delete job -l app=shiro-tests --ignore-not-found
$K -n "$NODE_NS" delete job -l app=shiro-tests --ignore-not-found

$K apply -k manifests/tests

status=0
for ns in "$CORE_NS" "$NODE_NS"; do
  if ! $K -n "$ns" wait --for=condition=complete job -l app=shiro-tests \
    --timeout="${TIMEOUT}s"; then
    status=1
    break
  fi
done

for ns in "$CORE_NS" "$NODE_NS"; do
  $K -n "$ns" logs -l app=shiro-tests --tail=-1 --prefix || true
done

exit "$status"
