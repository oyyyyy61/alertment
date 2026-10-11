#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KPS_CHART_VERSION=${KPS_CHART_VERSION:-92.1.1}
DCGM_CHART_VERSION=${DCGM_CHART_VERSION:-4.8.4}
KPS_CHART=${KPS_CHART:-prometheus-community/kube-prometheus-stack}
DCGM_CHART=${DCGM_CHART:-gpu-helm-charts/dcgm-exporter}

for required_command in kubectl helm openssl; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Required command is missing: $required_command" >&2
    exit 1
  fi
done

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "KUBECONFIG must point to the target RKE2 administrator kubeconfig." >&2
  exit 1
fi

if [[ ! -r "$KUBECONFIG" ]]; then
  echo "KUBECONFIG is not readable: $KUBECONFIG" >&2
  exit 1
fi

echo "Kubernetes context: $(kubectl config current-context)"
echo "Kubernetes API: $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
echo
kubectl cluster-info
kubectl get nodes -o wide

expected_nodes=(
  gpustack-cp01
  gpustack-cp02
  gpu-node-14
  gpu-node-15
)

for expected_node in "${expected_nodes[@]}"; do
  if ! kubectl get node "$expected_node" >/dev/null 2>&1; then
    echo "Target node is missing: $expected_node" >&2
    echo "Refusing to deploy because KUBECONFIG may point to the wrong cluster." >&2
    exit 1
  fi
done

for required_permission in \
  "create namespaces" \
  "create customresourcedefinitions.apiextensions.k8s.io"; do
  read -r verb resource <<<"$required_permission"
  if [[ "$(kubectl auth can-i "$verb" "$resource")" != "yes" ]]; then
    echo "Current Kubernetes identity cannot $verb $resource." >&2
    echo "Use the target RKE2 administrator kubeconfig for installation." >&2
    exit 1
  fi
done

needs_repo_update=false
if [[ ! -r "$KPS_CHART" ]]; then
  helm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts \
    --force-update
  needs_repo_update=true
fi
if [[ ! -r "$DCGM_CHART" ]]; then
  helm repo add gpu-helm-charts \
    https://nvidia.github.io/dcgm-exporter/helm-charts \
    --force-update
  needs_repo_update=true
fi
if [[ "$needs_repo_update" == true ]]; then
  helm repo update
fi

kubectl create namespace monitoring \
  --dry-run=client \
  -o yaml \
  | kubectl apply -f -

if ! kubectl -n monitoring get secret gpu-grafana-admin >/dev/null 2>&1; then
  grafana_password=$(openssl rand -base64 24 | tr -d '\n')
  kubectl -n monitoring create secret generic gpu-grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$grafana_password"
  unset grafana_password
fi

kps_args=(
  upgrade --install kube-prometheus-stack
  "$KPS_CHART"
  --namespace monitoring
  --create-namespace
  --values "$SCRIPT_DIR/values/kube-prometheus-stack.yaml"
  --wait
  --timeout 15m
)
if [[ ! -r "$KPS_CHART" && -n "$KPS_CHART_VERSION" ]]; then
  kps_args+=(--version "$KPS_CHART_VERSION")
fi
helm "${kps_args[@]}"

kubectl wait --for=condition=Established \
  customresourcedefinition/servicemonitors.monitoring.coreos.com \
  customresourcedefinition/podmonitors.monitoring.coreos.com \
  customresourcedefinition/scrapeconfigs.monitoring.coreos.com \
  customresourcedefinition/prometheusrules.monitoring.coreos.com \
  customresourcedefinition/alertmanagerconfigs.monitoring.coreos.com \
  --timeout=5m

kubectl apply -k "$SCRIPT_DIR/manifests"

dcgm_args=(
  upgrade --install dcgm-exporter
  "$DCGM_CHART"
  --namespace gpu-observability
  --values "$SCRIPT_DIR/values/dcgm-exporter.yaml"
  --wait
  --timeout 10m
)
if [[ ! -r "$DCGM_CHART" && -n "$DCGM_CHART_VERSION" ]]; then
  dcgm_args+=(--version "$DCGM_CHART_VERSION")
fi
helm "${dcgm_args[@]}"

echo
echo "Deployment complete. Run: $SCRIPT_DIR/verify.sh"
echo "Notification delivery remains disabled until a receiver such as examples/alertmanagerconfig-feishu.yaml is applied."
