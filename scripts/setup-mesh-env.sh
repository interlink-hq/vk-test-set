#!/usr/bin/env bash
# setup-mesh-env.sh — Set up a k3s + Traefik + interLink environment for
#                     testing the wstunnel mesh-network feature of vk-test-set.
#
# Requirements:
#   - sudo access (for k3s installation)
#   - docker, curl, python3 available
#
# Usage:
#   bash scripts/setup-mesh-env.sh
#
# Environment variables:
#   INTERLINK_VERSION  interLink release tag to download (default: auto-detect latest)
#   K3S_VERSION        k3s release to install          (default: v1.31.4+k3s1)
#   TEST_DIR           working directory                (default: /tmp/interlink-mesh-XXXXXX)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Setting up interLink mesh-network test environment ==="
echo "Repo root: ${REPO_ROOT}"

# ---------------------------------------------------------------------------
# Resolve test directory
# ---------------------------------------------------------------------------
if [[ -n "${TEST_DIR:-}" ]]; then
  echo "Using existing TEST_DIR: ${TEST_DIR}"
else
  TEST_DIR=$(mktemp -d /tmp/interlink-mesh-XXXXXX)
  echo "Created TEST_DIR: ${TEST_DIR}"
fi
STATE_FILE="/tmp/interlink-mesh-dir.txt"
echo "${TEST_DIR}" > "${STATE_FILE}"
echo "State file: ${STATE_FILE}"

# ---------------------------------------------------------------------------
# Determine Docker bridge IP (used as nip.io wildcard)
# ---------------------------------------------------------------------------
DOCKER_HOST_IP=$(docker network inspect bridge \
  --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null | head -1)
if [[ -z "${DOCKER_HOST_IP}" ]]; then
  DOCKER_HOST_IP="172.17.0.1"
fi
WILDCARD_DNS="${DOCKER_HOST_IP}.nip.io"
echo "Docker host IP  : ${DOCKER_HOST_IP}"
echo "Wildcard DNS    : ${WILDCARD_DNS}"
echo "${WILDCARD_DNS}" > "${TEST_DIR}/wildcard-dns.txt"

# ---------------------------------------------------------------------------
# Install k3s (keep Traefik enabled for IngressRoute support)
# ---------------------------------------------------------------------------
echo ""
echo "=== Installing k3s ==="
K3S_VERSION="${K3S_VERSION:-v1.31.4+k3s1}"
echo "k3s version: ${K3S_VERSION}"

curl -sfL https://get.k3s.io | \
  sudo env INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - \
  --egress-selector-mode disabled \
  2>&1 | tee "${TEST_DIR}/k3s-install.log"

sudo chmod 644 /etc/rancher/k3s/k3s.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "Waiting for k3s to be ready..."
for i in $(seq 1 30); do
  if kubectl get nodes 2>/dev/null | grep -q '.'; then
    break
  fi
  echo "  Waiting for node to appear... ($i/30)"
  sleep 5
done
kubectl wait --for=condition=Ready node --all --timeout=150s
echo "✓ k3s is ready"
kubectl get nodes

# Wait for Traefik to be fully deployed
echo "Waiting for Traefik to become ready..."
kubectl wait --namespace kube-system \
  --for=condition=available deployment/traefik \
  --timeout=120s 2>/dev/null || \
kubectl rollout status deployment/traefik -n kube-system --timeout=120s 2>/dev/null || \
echo "  (Traefik not yet settled — continuing)"
echo "✓ Traefik ready"

# ---------------------------------------------------------------------------
# Download interLink VK binary from releases
# ---------------------------------------------------------------------------
echo ""
echo "=== Downloading interLink virtual-kubelet binary ==="
if [[ -n "${INTERLINK_VERSION:-}" ]]; then
  VK_TAG="${INTERLINK_VERSION}"
else
  VK_TAG=$(curl -sSf https://api.github.com/repos/interlink-hq/interLink/releases/latest \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
fi
echo "interLink version: ${VK_TAG}"

VK_URL="https://github.com/interlink-hq/interLink/releases/download/${VK_TAG}/virtual-kubelet_Linux_x86_64"
curl -sSfL "${VK_URL}" -o "${TEST_DIR}/vk"
chmod +x "${TEST_DIR}/vk"
echo "✓ VK binary downloaded"

# ---------------------------------------------------------------------------
# Download interLink API and SLURM-plugin Docker images
# ---------------------------------------------------------------------------
echo ""
echo "=== Pulling interLink Docker images ==="
INTERLINK_IMAGE="ghcr.io/interlink-hq/interlink/interlink:${VK_TAG}"
PLUGIN_IMAGE="ghcr.io/interlink-hq/interlink-slurm-plugin/interlink-sidecar-slurm:latest"
docker pull "${INTERLINK_IMAGE}" 2>&1 | tail -3
docker pull "${PLUGIN_IMAGE}"    2>&1 | tail -3
echo "✓ Docker images pulled"

# ---------------------------------------------------------------------------
# Create Docker network for container-to-container communication
# ---------------------------------------------------------------------------
docker network create interlink-net 2>/dev/null || \
  echo "Docker network 'interlink-net' already exists, reusing."

# ---------------------------------------------------------------------------
# Runtime configs
# ---------------------------------------------------------------------------
mkdir -p "${TEST_DIR}/.interlink"

cat > "${TEST_DIR}/plugin-config.yaml" <<EOF
InterlinkURL: "http://interlink-api"
InterlinkPort: "3000"
SidecarURL: "http://0.0.0.0"
SidecarPort: "4000"
VerboseLogging: true
ErrorsOnlyLogging: false
DataRootFolder: "/tmp/.interlink/"
ExportPodData: true
SbatchPath: "/usr/bin/sbatch"
ScancelPath: "/usr/bin/scancel"
SqueuePath: "/usr/bin/squeue"
CommandPrefix: ""
SingularityPrefix: ""
ImagePrefix: "docker://"
Namespace: "default"
Tsocks: false
BashPath: /bin/bash
EnableProbes: true
EOF

cat > "${TEST_DIR}/interlink-config.yaml" <<EOF
InterlinkAddress: "http://0.0.0.0"
InterlinkPort: "3000"
SidecarURL: "http://interlink-plugin"
SidecarPort: "4000"
VerboseLogging: true
ErrorsOnlyLogging: false
DataRootFolder: "/tmp/.interlink-api"
EOF

# ---------------------------------------------------------------------------
# Start SLURM plugin container
# ---------------------------------------------------------------------------
echo ""
echo "=== Starting SLURM plugin container ==="
docker run -d --name interlink-plugin \
  --network interlink-net \
  -p 4000:4000 \
  --privileged \
  -v "${TEST_DIR}/plugin-config.yaml:/etc/interlink/InterLinkConfig.yaml:ro" \
  -e SHARED_FS=true \
  -e SLURMCONFIGPATH=/etc/interlink/InterLinkConfig.yaml \
  "${PLUGIN_IMAGE}"

sleep 5
docker ps --filter "name=interlink-plugin" --filter "status=running" | grep interlink-plugin \
  || { echo "ERROR: SLURM plugin failed to start"; docker logs interlink-plugin; exit 1; }
echo "✓ SLURM plugin started"

# ---------------------------------------------------------------------------
# Start interLink API container
# ---------------------------------------------------------------------------
echo ""
echo "=== Starting interLink API container ==="
docker run -d --name interlink-api \
  --network interlink-net \
  -p 3000:3000 \
  -v "${TEST_DIR}/interlink-config.yaml:/etc/interlink/InterLinkConfig.yaml:ro" \
  -e INTERLINKCONFIGPATH=/etc/interlink/InterLinkConfig.yaml \
  "${INTERLINK_IMAGE}"

sleep 3
docker ps --filter "name=interlink-api" --filter "status=running" | grep interlink-api \
  || { echo "ERROR: interLink API failed to start"; docker logs interlink-api; exit 1; }
echo "✓ interLink API started"

# ---------------------------------------------------------------------------
# RBAC for the virtual kubelet (cluster-admin for mesh namespace management)
# ---------------------------------------------------------------------------
echo ""
echo "=== Creating VK RBAC ==="
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: virtual-kubelet
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: virtual-kubelet-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: virtual-kubelet
  namespace: default
YAML
echo "✓ RBAC created"

# ---------------------------------------------------------------------------
# Create the VK kubeconfig via service-account token
# ---------------------------------------------------------------------------
echo "Creating VK kubeconfig..."
VK_TOKEN=$(kubectl create token virtual-kubelet -n default --duration=24h)
K8S_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
K8S_CA_DATA=$(kubectl config view --minify --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
if [[ -z "${K8S_CA_DATA}" ]]; then
  K8S_CA_FILE=$(kubectl config view --minify --raw \
    -o jsonpath='{.clusters[0].cluster.certificate-authority}')
  K8S_CA_DATA=$(base64 -w 0 < "${K8S_CA_FILE}" 2>/dev/null || base64 < "${K8S_CA_FILE}")
fi

cat > "${TEST_DIR}/vk-kubeconfig.yaml" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: default-cluster
  cluster:
    server: ${K8S_SERVER}
    certificate-authority-data: ${K8S_CA_DATA}
contexts:
- name: default-context
  context:
    cluster: default-cluster
    user: virtual-kubelet
    namespace: default
current-context: default-context
users:
- name: virtual-kubelet
  user:
    token: ${VK_TOKEN}
EOF
chmod 600 "${TEST_DIR}/vk-kubeconfig.yaml"
echo "✓ VK kubeconfig created"

# ---------------------------------------------------------------------------
# VK config — mesh networking enabled with nip.io wildcard DNS
# ---------------------------------------------------------------------------
cat > "${TEST_DIR}/vk-config.yaml" <<EOF
InterlinkURL: "http://0.0.0.0"
InterlinkPort: "3000"
VerboseLogging: true
ErrorsOnlyLogging: false
ServiceAccount: "virtual-kubelet"
Namespace: default
VKTokenFile: ""
Resources:
  CPU: "100"
  Memory: "128Gi"
  Pods: "100"
HTTP:
  Insecure: true
KubeletHTTP:
  Insecure: true
Network:
  EnableTunnel: true
  WildcardDNS: "${WILDCARD_DNS}"
  WstunnelTemplatePath: "${REPO_ROOT}/scripts/wstunnel-traefik-template.yaml"
EOF

# ---------------------------------------------------------------------------
# Start the virtual kubelet
# ---------------------------------------------------------------------------
echo ""
echo "=== Starting Virtual Kubelet ==="
POD_IP=$(hostname -I | awk '{print $1}')

NODENAME=virtual-kubelet \
  KUBELET_PORT=10251 \
  KUBELET_URL=0.0.0.0 \
  POD_IP="${POD_IP}" \
  CONFIGPATH="${TEST_DIR}/vk-config.yaml" \
  KUBECONFIG="${TEST_DIR}/vk-kubeconfig.yaml" \
  nohup "${TEST_DIR}/vk" > "${TEST_DIR}/vk.log" 2>&1 &

VK_PID=$!
echo "${VK_PID}" > "${TEST_DIR}/vk.pid"
echo "VK started with PID ${VK_PID}"

# ---------------------------------------------------------------------------
# Wait for the virtual-kubelet node to register
# ---------------------------------------------------------------------------
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "Waiting for virtual-kubelet node..."
for i in $(seq 1 60); do
  if kubectl get node virtual-kubelet &>/dev/null; then
    echo "✓ virtual-kubelet node registered"
    break
  fi
  kill -0 "${VK_PID}" 2>/dev/null || {
    echo "ERROR: VK process exited early!"
    tail -50 "${TEST_DIR}/vk.log" || true
    exit 1
  }
  echo "  Waiting... ($i/60)"
  sleep 5
done
kubectl get node virtual-kubelet || {
  echo "ERROR: VK did not register"
  tail -100 "${TEST_DIR}/vk.log" || true
  exit 1
}

echo "Waiting for virtual-kubelet node to become Ready..."
kubectl wait --for=condition=Ready node/virtual-kubelet --timeout=300s || {
  echo "ERROR: VK node not Ready"
  kubectl describe node virtual-kubelet || true
  tail -100 "${TEST_DIR}/vk.log" || true
  exit 1
}
echo "✓ virtual-kubelet node is Ready"

# ---------------------------------------------------------------------------
# Approve kubelet-serving CSRs (needed for kubectl logs)
# ---------------------------------------------------------------------------
echo ""
echo "=== Approving CSRs ==="
for i in $(seq 1 30); do
  kubectl get csr 2>/dev/null | awk 'NR>1' | grep -q . && break
  echo "  No CSRs yet... ($i/30)"
  sleep 2
done
PENDING=$(kubectl get csr 2>/dev/null | awk 'NR>1 && /Pending/ {print $1}')
[[ -n "${PENDING}" ]] && echo "${PENDING}" | xargs kubectl certificate approve || true
for i in $(seq 1 20); do
  NEW_PENDING=$(kubectl get csr 2>/dev/null | awk 'NR>1 && /Pending/ {print $1}')
  [[ -n "${NEW_PENDING}" ]] && echo "${NEW_PENDING}" | xargs kubectl certificate approve 2>/dev/null || true
  kubectl get csr 2>/dev/null | grep -E "Approved,Issued" | grep -qi "virtual-kubelet" && { echo "✓ CSRs approved"; break; }
  echo "  Waiting for CSR issuance... ($i/20)"
  sleep 3
done

# ---------------------------------------------------------------------------
# Create interlink namespace
# ---------------------------------------------------------------------------
kubectl create namespace interlink 2>/dev/null || true
kubectl label node virtual-kubelet kubernetes.io/hostname=virtual-kubelet --overwrite 2>/dev/null || true

echo ""
echo "=== Environment ready ==="
echo "  KUBECONFIG : /etc/rancher/k3s/k3s.yaml"
echo "  TEST_DIR   : ${TEST_DIR}"
echo "  VK PID     : ${VK_PID}"
echo "  WildcardDNS: ${WILDCARD_DNS}"
echo "  VK log     : ${TEST_DIR}/vk.log"
