#!/bin/bash
# GPU stack EGS needs on OpenShift: Red Hat NFD Operator + NVIDIA GPU Operator (cluster-admin required).
# Run BEFORE the EGS installer, then install EGS with --skip-controller-gpu-operator / --skip-worker-gpu-operator.
#
#   ./openshift-gpu-stack.sh apply      # NFD Operator + NFD instance + GPU Operator, wait until ready
#   ./openshift-gpu-stack.sh verify     # operator state, GPU nodes, driver version
#   ./openshift-gpu-stack.sh cuda-test  # run the CUDA vectorAdd sample pod and clean it up
#
# Uses KUBECONFIG / current context. Idempotent: safe to re-run.
# Optional overrides: GPU_OPERATOR_VERSION (default v25.3.4), GPU_OPERATOR_NS (default egs-gpu-operator),
#                     VALUES_FILE (default ./gpu-operator-ocp-values.yaml, also reusable in egs-installer-config.yaml)
set -euo pipefail

ACTION="${1:-}"
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v25.3.4}"
GPU_OPERATOR_NS="${GPU_OPERATOR_NS:-egs-gpu-operator}"
VALUES_FILE="${VALUES_FILE:-gpu-operator-ocp-values.yaml}"

case "$ACTION" in
  apply|verify|cuda-test) ;;
  *) echo "usage: $0 apply|verify|cuda-test" >&2; exit 1 ;;
esac

for tool in oc helm; do
  command -v "$tool" >/dev/null || { echo "❌ $tool not found in PATH" >&2; exit 1; }
done
oc get clusterversion version >/dev/null 2>&1 || { echo "❌ Not an OpenShift cluster (or API unreachable). Check KUBECONFIG." >&2; exit 1; }
[ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null)" = "yes" ] || { echo "❌ cluster-admin is required." >&2; exit 1; }

# wait_for <description> <timeout-seconds> <command...>: poll until the command succeeds
wait_for() {
  local what="$1" timeout="$2"; shift 2
  local end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    [ $SECONDS -ge $end ] && { echo "❌ Timed out waiting for: $what" >&2; return 1; }
    sleep 10
  done
}

install_nfd_operator() {
  echo "▶ 1/4 Red Hat Node Feature Discovery Operator"
  oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nfd
  namespace: openshift-nfd
spec:
  targetNamespaces:
  - openshift-nfd
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: stable
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
  local csv=""
  wait_for "NFD ClusterServiceVersion" 600 bash -c \
    'oc -n openshift-nfd get subscription nfd -o jsonpath="{.status.installedCSV}" | grep -q .' || {
      cat >&2 <<'EOF'
   If the Subscription's InstallPlan failed because nodefeaturerules.nfd.k8s-sigs.io cannot change scope,
   a GPU Operator release with its bundled NFD was installed earlier. Remove that NFD (nfd.enabled=false),
   make sure no nodefeaturerules / nodefeatures objects remain, delete those two CRDs, delete the
   Subscription and CSV in openshift-nfd, and run this script again.
EOF
      return 1; }
  csv=$(oc -n openshift-nfd get subscription nfd -o jsonpath='{.status.installedCSV}')
  oc -n openshift-nfd wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$csv" --timeout=10m
}

install_nfd_instance() {
  echo "▶ 2/4 NodeFeatureDiscovery instance"
  oc apply -f - <<'EOF'
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    imagePullPolicy: IfNotPresent
    servicePort: 12000
  workerConfig:
    configData: |
      core:
        sleepInterval: 60s
      sources:
        pci:
          deviceClassWhitelist:
            - "0200"
            - "03"
            - "12"
          deviceLabelFields:
            - "vendor"
EOF
  wait_for "nfd-worker DaemonSet" 300 oc -n openshift-nfd get ds/nfd-worker
  oc -n openshift-nfd rollout status ds/nfd-worker --timeout=5m
  # 10de = NVIDIA PCI vendor ID; allow time for the first scan
  wait_for "a node labelled feature.node.kubernetes.io/pci-10de.present=true" 300 bash -c \
    'oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o name | grep -q .'
  oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true
}

install_gpu_operator() {
  echo "▶ 3/4 NVIDIA GPU Operator $GPU_OPERATOR_VERSION"
  cat > "$VALUES_FILE" <<'EOF'
platform:
  openshift: true               # OpenShift SCCs for the operator and operands
operator:
  use_ocp_driver_toolkit: true  # driver built on each node with the OpenShift Driver Toolkit (no entitlement)
nfd:
  enabled: false                # NFD comes from the Red Hat NFD Operator (steps 1-2)
cdi:
  enabled: true
  default: true
driver:
  enabled: true                 # driver container, chart default version
dcgm:
  enabled: true                 # standalone DCGM host engine, required by egs-gpu-agent
validator:
  plugin:
    env:
    - name: WITH_WORKLOAD
      value: "false"
daemonsets:
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  - key: kubeslice.io/egs        # EGS taints dedicated GPU nodes kubeslice.io/egs=dedicated-node:NoSchedule
    operator: Exists
    effect: NoSchedule
EOF
  echo "   values written to $VALUES_FILE"
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia --force-update >/dev/null
  helm repo update nvidia >/dev/null
  helm upgrade --install gpu-operator nvidia/gpu-operator --version "$GPU_OPERATOR_VERSION" \
    -n "$GPU_OPERATOR_NS" --create-namespace -f "$VALUES_FILE"
}

wait_ready() {
  echo "▶ 4/4 Waiting for the GPU Operator to report ready (driver build takes about 5-10 minutes)"
  # the ClusterPolicy is created shortly after the Helm release; 'oc wait' fails if it does not exist yet
  wait_for "ClusterPolicy cluster-policy to exist" 300 oc get clusterpolicy/cluster-policy
  # The ClusterPolicy can read 'ready' for a moment before the operator has reconciled, so first wait for the
  # real outcome: every NVIDIA node advertises an allocatable nvidia.com/gpu.
  wait_for "nvidia.com/gpu allocatable on every GPU node" 1800 bash -c '
    nodes=$(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o name)
    [ -n "$nodes" ] || exit 1
    for n in $nodes; do
      g=$(oc get "$n" -o jsonpath="{.status.allocatable.nvidia\.com/gpu}")
      [ -n "$g" ] && [ "$g" != "0" ] || exit 1
    done'
  oc wait clusterpolicy/cluster-policy --for=jsonpath='{.status.state}'=ready --timeout=30m
}

verify() {
  echo "▶ ClusterPolicy state: $(oc get clusterpolicy/cluster-policy -o jsonpath='{.status.state}')"
  oc get nodes -l nvidia.com/gpu.present=true \
    -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,MODEL:.metadata.labels.nvidia\.com/gpu\.product'
  for p in $(oc -n "$GPU_OPERATOR_NS" get pods -o name | grep nvidia-driver-daemonset || true); do
    oc -n "$GPU_OPERATOR_NS" exec "$p" -c nvidia-driver-ctr -- \
      nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
  done
}

cuda_test() {
  trap 'oc -n default delete pod cuda-vectoradd --ignore-not-found >/dev/null 2>&1' EXIT
  oc -n default delete pod cuda-vectoradd --ignore-not-found >/dev/null
  oc apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vectoradd
  namespace: default
spec:
  restartPolicy: OnFailure
  tolerations:
  - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}
  - {key: kubeslice.io/egs, operator: Exists, effect: NoSchedule}
  containers:
  - name: cuda-vectoradd
    image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0
    resources:
      limits:
        nvidia.com/gpu: 1
    securityContext:
      allowPrivilegeEscalation: false
      capabilities: {drop: [ALL]}
      seccompProfile: {type: RuntimeDefault}
EOF
  oc -n default wait pod/cuda-vectoradd --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m
  oc -n default logs cuda-vectoradd        # expect "Test PASSED"
}

case "$ACTION" in
  apply)     install_nfd_operator; install_nfd_instance; install_gpu_operator; wait_ready; verify
             echo "✅ GPU stack ready. Install EGS with --skip-controller-gpu-operator --skip-worker-gpu-operator." ;;
  verify)    verify ;;
  cuda-test) cuda_test ;;
esac
