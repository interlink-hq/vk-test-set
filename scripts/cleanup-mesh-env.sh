#!/usr/bin/env bash
# cleanup-mesh-env.sh — Tear down the mesh-network test environment created
#                       by setup-mesh-env.sh.
#
# Usage:
#   bash scripts/cleanup-mesh-env.sh
#
# Optional:
#   REMOVE_TEST_DIR=1  also delete the temporary test directory

set -euo pipefail

echo "=== Cleaning up mesh-network test environment ==="

STATE_FILE="/tmp/interlink-mesh-dir.txt"

# Stop virtual kubelet
if [[ -f "${STATE_FILE}" ]]; then
  TEST_DIR=$(cat "${STATE_FILE}")
  if [[ -f "${TEST_DIR}/vk.pid" ]]; then
    VK_PID=$(cat "${TEST_DIR}/vk.pid")
    echo "Stopping VK (PID ${VK_PID})..."
    kill "${VK_PID}" 2>/dev/null || true
    sleep 2
    kill -9 "${VK_PID}" 2>/dev/null || true
  fi
fi

# Save Docker logs before stopping containers
if [[ -f "${STATE_FILE}" ]]; then
  TEST_DIR=$(cat "${STATE_FILE}")
  if [[ -n "${TEST_DIR}" && -d "${TEST_DIR}" ]]; then
    echo "Saving container logs..."
    docker logs interlink-api    > "${TEST_DIR}/interlink-api.log"    2>&1 || true
    docker logs interlink-plugin > "${TEST_DIR}/interlink-plugin.log" 2>&1 || true
  fi
fi

# Remove Docker containers and network
echo "Removing Docker containers..."
docker stop interlink-api    2>/dev/null || true
docker rm   interlink-api    2>/dev/null || true
docker stop interlink-plugin 2>/dev/null || true
docker rm   interlink-plugin 2>/dev/null || true
docker network rm interlink-net 2>/dev/null || true

# Uninstall k3s
echo "Uninstalling k3s..."
if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
  sudo /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
else
  echo "  k3s uninstall script not found, skipping."
fi

# Optionally remove test directory
if [[ -f "${STATE_FILE}" ]]; then
  TEST_DIR=$(cat "${STATE_FILE}")
  if [[ "${REMOVE_TEST_DIR:-0}" == "1" ]]; then
    echo "Removing ${TEST_DIR}..."
    rm -rf "${TEST_DIR}" 2>/dev/null || true
    rm -f "${STATE_FILE}"
  else
    echo "Preserving test directory for debugging: ${TEST_DIR}"
    echo "(set REMOVE_TEST_DIR=1 to delete it)"
  fi
fi

echo "✓ Cleanup complete"
