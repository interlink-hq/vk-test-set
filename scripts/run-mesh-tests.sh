#!/usr/bin/env bash
# run-mesh-tests.sh — Run the vk-test-set integration tests against the
#                     mesh-network environment set up by setup-mesh-env.sh.
#
# Usage:
#   bash scripts/run-mesh-tests.sh
#
# Requires setup-mesh-env.sh to have been run first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Read test directory written by setup-mesh-env.sh
STATE_FILE="/tmp/interlink-mesh-dir.txt"
if [[ ! -f "${STATE_FILE}" ]]; then
  echo "ERROR: state file ${STATE_FILE} not found. Run setup-mesh-env.sh first."
  exit 1
fi
TEST_DIR=$(cat "${STATE_FILE}")

echo "=== Running vk-test-set mesh integration tests ==="
echo "TEST_DIR: ${TEST_DIR}"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
WILDCARD_DNS=$(cat "${TEST_DIR}/wildcard-dns.txt" 2>/dev/null || echo "")

echo "Cluster status:"
kubectl get nodes
kubectl get pods -A --field-selector="metadata.namespace!=kube-system" 2>/dev/null | head -20 || true

# Wait for the virtual-kubelet node to be Ready
echo "Waiting for virtual-kubelet node..."
for i in {1..30}; do
  kubectl get node virtual-kubelet &>/dev/null && break
  echo "  ($i/30) waiting..."
  sleep 5
done
kubectl wait --for=condition=Ready node/virtual-kubelet --timeout=120s || {
  echo "ERROR: virtual-kubelet node not Ready"
  kubectl describe node virtual-kubelet || true
  tail -50 "${TEST_DIR}/vk.log" || true
  exit 1
}
echo "✓ virtual-kubelet is Ready"

# ---------------------------------------------------------------------------
# Write test configuration
# ---------------------------------------------------------------------------
cat > "${REPO_ROOT}/vktest_config_mesh.yaml" <<EOF
target_nodes:
  - virtual-kubelet

required_namespaces:
  - default
  - kube-system
  - interlink

timeout_multiplier: 3.0

values:
  namespace: interlink

  annotations: {}

  tolerations:
    - key: virtual-node.interlink/no-schedule
      operator: Exists
      effect: NoSchedule
EOF

# ---------------------------------------------------------------------------
# Set up Python venv and install vk-test-set
# ---------------------------------------------------------------------------
echo "Installing vk-test-set..."
python3 -m venv "${TEST_DIR}/.venv"
source "${TEST_DIR}/.venv/bin/activate"
pip install -q -e "${REPO_ROOT}/"
echo "✓ vk-test-set installed"

# ---------------------------------------------------------------------------
# Run the tests — focus on mesh-network template plus smoke tests
# ---------------------------------------------------------------------------
echo ""
echo "========================================="
echo "Running integration tests..."
echo "WildcardDNS: ${WILDCARD_DNS}"
echo "========================================="

cd "${REPO_ROOT}"
VKTEST_CONFIG="${REPO_ROOT}/vktest_config_mesh.yaml" \
  pytest -v \
    -k "not rclone and not limits and not stress and not multi-init" \
    2>&1 | tee "${TEST_DIR}/test-results.log"
TEST_EXIT=${PIPESTATUS[0]}

echo "========================================="
if [[ "${TEST_EXIT}" -eq 0 ]]; then
  echo "✓ All tests passed"
else
  echo "✗ Tests failed (exit ${TEST_EXIT})"
  echo "Logs:"
  echo "  Test results : ${TEST_DIR}/test-results.log"
  echo "  VK log       : ${TEST_DIR}/vk.log"
  echo "  API logs     : docker logs interlink-api"
  echo "  Plugin logs  : docker logs interlink-plugin"
fi

exit "${TEST_EXIT}"
