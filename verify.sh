#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "KUBECONFIG must point to the target RKE2 administrator kubeconfig." >&2
  exit 1
fi

echo "== Nodes =="
kubectl get nodes -o wide

echo
echo "== Monitoring pods =="
kubectl -n monitoring get pods -o wide

echo
echo "== GPU observability objects =="
kubectl -n gpu-observability get pods,service,servicemonitor,podmonitor,scrapeconfig,prometheusrule -o wide

echo
echo "== DCGM rollout =="
kubectl -n gpu-observability rollout status daemonset/dcgm-exporter --timeout=2m

echo
echo "== GPU process exporter rollout =="
kubectl -n gpu-observability rollout status daemonset/gpu-process-exporter --timeout=2m

echo
echo "== Kueue metrics monitor =="
kubectl -n gpu-observability get servicemonitor kueue-controller-manager

echo
echo "== Prometheus target discovery inputs =="
kubectl get servicemonitor,podmonitor,scrapeconfig -A

echo
echo "GPUStack Worker HTTP discovery configuration:"
kubectl -n gpu-observability get scrapeconfig gpustack-worker-discovery -o yaml
