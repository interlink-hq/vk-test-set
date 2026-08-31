#!/bin/bash
# k3s-test-run.sh - Run vk-test-set integration tests on K3s cluster

set -e

# Get test directory from previous setup
if [ -f /tmp/interlink-test-dir.txt ]; then
  TEST_DIR=$(cat /tmp/interlink-test-dir.txt)
else
  echo "ERROR: Test directory not found. Did you run k3s-test-setup.sh first?"
  exit 1
fi

echo "=== Running vk-test-set integration tests ==="
echo "Test directory: ${TEST_DIR}"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Check cluster status
kubectl get nodes
kubectl get pods -A

# Wait for virtual-kubelet node to be Ready
echo "Waiting for virtual-kubelet node..."
if ! kubectl wait --for=condition=Ready node/virtual-kubelet --timeout=120s; then
  echo "ERROR: virtual-kubelet node is not Ready"
  kubectl describe node virtual-kubelet || true
  tail -100 "${TEST_DIR}/vk.log" || true
  docker logs interlink-api --tail=50 || true
  docker logs interlink-plugin --tail=50 || true
  exit 1
fi
echo "virtual-kubelet node is Ready"

# Approve any pending CSRs
kubectl get csr -o name | xargs -r kubectl certificate approve 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}"

# Create test configuration
cat > vktest_config.yaml << CFGEOF
target_nodes:
  - virtual-kubelet

required_namespaces:
  - default
  - kube-system

timeout_multiplier: 10.
values:
  namespace: default

  annotations: {}

  tolerations:
    - key: virtual-node.interlink/no-schedule
      operator: Exists
      effect: NoSchedule
CFGEOF

# Setup Python virtual environment and install vk-test-set
echo "Setting up Python environment..."
python3 -m venv .venv
source .venv/bin/activate
pip3 install -e ./ || {
  echo "ERROR: Failed to install vk-test-set"
  exit 1
}

echo "=== Running integration tests ==="
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
pytest -v -k "not rclone and not limits and not stress and not multi-init and not fail" 2>&1 | tee "${TEST_DIR}/test-results.log"
TEST_EXIT_CODE=${PIPESTATUS[0]}

if [ ${TEST_EXIT_CODE} -eq 0 ]; then
  echo "All tests passed!"
else
  echo "Some tests failed (exit code: ${TEST_EXIT_CODE})"
fi

exit ${TEST_EXIT_CODE}
