# Find who is using a GPU

Use all three views below. A Kubernetes Pod, a GPUStack inference request, and a
local desktop process have different owners.

## 1. GPUStack inference ownership

GPUStack 2.2.3 exposes usage grouped by user, API key, route, and organization.
Use the **Usage** page in `http://gpustack.sdnware.com` for the normal operator
workflow.

The API supports the same data. Keep the key in an environment variable:

```bash
export GPUSTACK_API_KEY='<api-key>'
curl -sS \
  -H "X-API-Key: ${GPUSTACK_API_KEY}" \
  'http://gpustack.sdnware.com/v2/usage/summary?start_date=2026-10-01&end_date=2026-10-08&scope=all' \
  | jq

curl -sS \
  -H "X-API-Key: ${GPUSTACK_API_KEY}" \
  'http://gpustack.sdnware.com/v2/usage/resource-events?start_date=2026-10-08&end_date=2026-10-08&perPage=100' \
  | jq
```

Prometheus shows the currently loaded instances:

```promql
count by (worker_name, model_name, model_instance_name, runtime) (
  gpustack:num_requests_running
)
```

Active and waiting requests:

```promql
sum by (worker_name, model_instance_name) (gpustack:num_requests_running)
sum by (worker_name, model_instance_name) (gpustack:num_requests_waiting)
```

## 2. Kubernetes workload ownership

List Pods that request NVIDIA GPUs:

```bash
kubectl get pods -A -o json | jq -r '
  .items[]
  | [
      .metadata.namespace,
      .metadata.name,
      (.spec.nodeName // "<pending>"),
      (.metadata.labels["observability.gpustack.io/owner"] // "<unlabeled>"),
      (.metadata.labels["observability.gpustack.io/project"] // "<unlabeled>"),
      ([.spec.containers[].resources.requests["nvidia.com/gpu"] // empty] | add // 0)
    ]
  | select(.[5] != 0)
  | @tsv'
```

Prometheus maps live GPU telemetry to Pods:

```promql
DCGM_FI_DEV_FB_USED{pod!=""}
DCGM_FI_DEV_GPU_UTIL{pod!=""}
```

The `GPUResourceInUse` and `KubernetesGPUAllocationActive` alerts fire when the
allocation becomes active. Their resolved notifications represent release.

## 3. Host and desktop process ownership

Run on the GPU node:

```bash
nvidia-smi pmon -c 1
nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory \
  --format=csv,noheader,nounits
```

Map a PID to its operating-system user and command:

```bash
ps -o user=,pid=,lstart=,cmd= -p <pid>
cat /proc/<pid>/cgroup
```

At inspection time on `gpu-node-14`, user `og` ran PID `15955`
(`Hollow Knight Silksong`), which generated most of the graphics load. Xorg,
GNOME, Codex, Firefox, WeChat, and Steam also had graphics contexts. These
processes do not have Kubernetes owner labels.

DCGM reports this class of activity through `GPUHostUseUnattributed`. Keep
process names and PIDs out of long-retention metrics when possible because
short-lived PIDs create high-cardinality time series. Use the alert as the
trigger, then inspect the node with the commands above.

## Operational policy

- Require the four ownership labels on submitted GPU workloads.
- Give each person or service its own GPUStack account and API key.
- Submit batch/training work through Kueue.
- Treat unlabelled Pods as a policy violation.
- Treat local host GPU activity on cluster nodes as unowned capacity use.
- Dedicate `.14` to the cluster when predictable scheduling matters, or reserve
  it as a mixed desktop/cluster node and lower its scheduling priority.
