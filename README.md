# GPU 集群监控与飞书告警（alertment）

面向 GPUStack/RKE2 GPU 集群的完整可观测性与飞书告警方案：从指标采集、告警评估到
中文飞书消息投递的全链路，所有组件均为可直接 `kubectl apply` 的声明式清单，配合
两份脚本即可在同类环境中复现。

当前集群背景（复现时按实际情况替换）：

```text
192.168.50.11  gpustack-cp02   控制面（RKE2 server）
192.168.50.12  gpustack-cp01   控制面（RKE2 server）
192.168.50.14  gpu-node-14     GPU：GTX 1650（4GB）
192.168.50.15  gpu-node-15     GPU：RTX 4090（24GB）
192.168.50.20  higress 网关    GPUStack API
```

## 总体架构与数据流

告警链路分四层，每层只做一件事：

```text
┌─────────────── 采集层：谁来当数据源 ───────────────┐
│ GPUStack Worker :10151     模型实例/请求/显存        │
│ GPUStack Server :10161     Worker 动态发现(HTTP SD)  │
│ dcgm-exporter :9400        GPU 硬件/Pod 归属         │
│ gpu-process-exporter :9500 宿主机 CUDA 进程归属      │
│ kube-state-metrics         Pod/GPU 分配/归属标签     │
│ Kueue metrics              排队/驱逐                 │
│ node-exporter              主机 CPU/内存/磁盘        │
└──────────────────────┬─────────────────────────────┘
                       ↓ 15s 抓取
┌─────────────── 评估层：Prometheus ─────────────────┐
│ PrometheusRule（prometheus-rules.yaml）             │
│ 表达式成立并持续 for 时长 → Pending → Firing        │
└──────────────────────┬─────────────────────────────┘
                       ↓ webhook
┌─────────────── 分发层：Alertmanager ───────────────┐
│ AlertmanagerConfig（按 category=.+ 过滤）           │
│ 分组/去重/静默；生命周期告警独立子路由               │
│ firing=资源开始占用  resolved=资源释放              │
└──────────────────────┬─────────────────────────────┘
                       ↓ POST /alerts (JSON)
┌─────────────── 通知层：feishu-adapter ─────────────┐
│ Alertmanager JSON → 中文飞书文本消息                │
│ 事件时间转北京时间、签名验证、发送时资源余量快照      │
└──────────────────────┬─────────────────────────────┘
                       ↓ webhook（自定义机器人）
                    飞书群
```

三个关键语义，理解了它们整条链路就通了：

1. **firing/resolved 是一对生命周期事件**。`GPUProcessStarted` 这类规则在资源出现时
   firing、消失时 resolved，飞书里分别对应"任务已开始/已结束"两条消息。
2. **`category` 标签是通知过滤器**。AlertmanagerConfig 的根路由只匹配
   `category=~.+`，因此 Prometheus 自带的常驻 `Watchdog` 和平台无关告警不会打扰
   飞书群。
3. **AlertmanagerConfigMatcherStrategy 设为 None**。kube-prometheus-stack 默认会给
   AlertmanagerConfig 强制加 namespace 匹配器，置为 None 后自定义路由才能按标签命中
   任意 namespace 的告警。

## 目录结构

```text
alertment/
├── README.md                          本文档
├── docs/
│   ├── 01-部署指南.md                  从零复现的完整部署步骤
│   ├── 02-告警规则详解.md              每条规则的含义、表达式与设计动机
│   ├── 03-飞书适配器详解.md            adapter.py 结构与消息格式
│   └── 04-验证与运维.md                验证方法、端到端测试、常见问题
├── manifests/                         kustomize 清单（采集器 + 告警规则 + 面板）
│   ├── namespace.yaml
│   ├── gpustack-workers.yaml          Server 指标 + Worker HTTP 动态发现
│   ├── gpu-process-exporter.yaml      宿主机 CUDA 进程归属采集器（439 行，含完整 exporter 实现）
│   ├── prometheus-rules.yaml          全部告警规则（6 组 27 条）
│   ├── training-progress-podmonitor.yaml
│   ├── kueue-servicemonitor.yaml
│   ├── grafana-dashboard.yaml
│   └── kustomization.yaml
├── examples/
│   ├── feishu-adapter.yaml            飞书适配器（ConfigMap + Deployment + Service）
│   ├── alertmanagerconfig-feishu.yaml 飞书接收器路由（生产在用）
│   └── alertmanagerconfig-webhook.yaml 通用 webhook 接收器（无凭证示例）
├── values/
│   ├── kube-prometheus-stack.yaml     Helm values（组件选择器/存储/归属标签）
│   └── dcgm-exporter.yaml             GPU 节点选择 + 自定义指标列表
├── runbooks/who-is-using-gpu.md       "这块 GPU 谁在用"运维手册
├── node-config/gpu-node-15-kubelet.conf  kubelet 镜像 GC 阈值（可选）
├── deploy.sh                          一键部署监控栈与清单
└── verify.sh                          部署后体检
```

## 快速复现（五步）

前提：一个 RKE2 集群（有 GPU 节点）、GPUStack v2 已安装、Longhorn 存储、本机有
kubectl/helm/openssl。详细步骤与每个命令的解释见
[docs/01-部署指南.md](docs/01-部署指南.md)。

```bash
# 1. 准备 RKE2 管理员 kubeconfig（不要进 Git）
export KUBECONFIG="$HOME/.kube/gpustack-rke2.yaml"

# 2. 部署监控栈：kube-prometheus-stack + 告警规则 + 采集器
./deploy.sh

# 3. 在飞书群添加"自定义机器人"，拿到 webhook URL 和签名密钥，创建 Secret：
read -rsp 'Feishu webhook URL: ' FEISHU_WEBHOOK && echo
read -rsp 'Feishu signing secret: ' FEISHU_SECRET && echo
kubectl -n gpu-observability create secret generic feishu-gpu-alerts \
  --from-literal=webhook-url="$FEISHU_WEBHOOK" \
  --from-literal=signing-secret="$FEISHU_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -
unset FEISHU_WEBHOOK FEISHU_SECRET

# 4. 部署飞书适配器与接收器路由
kubectl apply -f examples/feishu-adapter.yaml
kubectl apply -f examples/alertmanagerconfig-feishu.yaml

# 5. 验证
./verify.sh
kubectl -n gpu-observability rollout status deployment/alertmanager-feishu-adapter
```

发一条端到端测试消息（模拟 Alertmanager 的 webhook 调用）：

```bash
kubectl -n gpu-observability run feishu-alert-test \
  --rm -i --restart=Never --image=curlimages/curl:8.12.1 -- \
  curl -fsS -H 'Content-Type: application/json' \
  --data '{"status":"firing","commonLabels":{"alertname":"FeishuDeliveryTest","cluster":"gpustack-rke2"},"alerts":[{"status":"firing","labels":{"alertname":"FeishuDeliveryTest","severity":"info","category":"test","node":"gpu-node-15"},"annotations":{"summary":"GPU 中文告警投递测试"},"startsAt":"2026-10-11T00:00:00Z"}]}' \
  http://alertmanager-feishu-adapter:8080/alerts
```

## 告警规则清单

完整表达式、`for` 时长与设计动机见 [docs/02-告警规则详解.md](docs/02-告警规则详解.md)。

| 分组 | 告警 | 含义 | 级别 |
| --- | --- | --- | --- |
| gpustack.worker | GPUStackWorkerMetricsDown | Worker 指标连续 2 分钟不可采 | 严重 |
| gpustack.worker | GPUStackWorkerDiscoveryMissing | Worker 动态发现为空 5 分钟 | 严重 |
| gpustack.worker | GPUStackServerMetricsDown | Server 指标不可用 2 分钟 | 严重 |
| gpustack.worker | GPUStackWorkerRootFilesystemHigh | Worker 根分区 >95% 持续 10 分钟 | 警告 |
| gpustack.worker | GPUStackGPUHighTemperature | GPU 温度 >82°C 持续 5 分钟 | 警告 |
| gpustack.worker | GPUStackModelInstanceLoaded | 模型实例真正运行中（实例级"已加载/已卸载"生命周期） | 信息 |
| gpustack.worker | GPUStackRequestErrors | 5 分钟内出现 error/abort 请求 | 警告 |
| gpustack.worker | GPUStackRequestQueueBacklog | 请求持续排队 10 分钟 | 警告 |
| gpustack.worker | GPUStackUnattributedWorkerUse | GPU 活动 >20% 却无模型实例 | 警告 |
| dcgm.hardware | DCGMExporterDown / GPUXIDError / GPUHealthWarning | 采集器/XID/健康检查 | 严重 |
| dcgm.hardware | DCGMGPUHighTemperature / DCGMGPUMemoryNearlyFull | 温度 >85°C / 显存 >95% | 严重/警告 |
| dcgm.hardware | GPUResourceInUse | Pod 开始使用 GPU >512MiB（生命周期） | 信息 |
| dcgm.hardware | GPUHostUseUnattributed | 主机进程占用 GPU >512MiB 未归属 | 警告 |
| dcgm.hardware | GPUAllocatedButIdle | 已分配 GPU 空闲 >15 分钟 | 警告 |
| dcgm.hardware | GPUDoubleBitECCError | 双比特 ECC 错误 | 严重 |
| kubernetes.gpu-allocation | KubernetesGPUAllocationActive | 带 GPU 的 Pod 进入 Running（生命周期） | 信息 |
| kueue.workloads | KueueMetricsMissing / KueueWorkloadsPending / KueueWorkloadEvicted | 排队系统三类事件 | 警告 |
| gpu.processes | GPUProcessExporterDown | 进程采集器不可用 | 严重 |
| gpu.processes | GPUProcessStarted | 宿主机 GPU 任务进程开始/结束（生命周期） | 信息 |
| gpu.processes | GPUProcessLongRunning | 进程运行超过 5 小时 | 警告 |
| training.progress | GPUTrainingStalled / GPUTrainingCompleted | 训练进度停滞/完成 | 警告/信息 |

## 飞书消息格式示例

适配器把每条告警渲染成中文文本消息，开头横幅一眼可辨事件类型，附发送时的资源余量
快照。任务开始：

```text
【GPU 任务·开始 🟢】GPU 任务进程已开始
集群：gpustack-rke2

1. 🟢 GPU 任务进程已开始
状态：已触发 | 级别：信息
告警代码：GPUProcessStarted
类别：资源状态
节点：gpu-node-15
进程：python
PID：9500
负责人：25_wb
任务：train_bounded.py
事件：进程已启动
摘要：用户 25_wb 的任务进程 train_bounded.py 已开始运行
触发时间（北京时间）：2026-10-11 15:00:00
进程启动时间（北京时间）：2026-10-11 14:09:51
资源余量（发送时）：
GPU 剩余显存：1.2 GiB / 24.0 GiB
GPU 利用率：98%，温度：68 C
```

任务结束（含"接续提示"——见下面第 2 条设计决策）：

```text
【GPU 任务·结束 🔴】GPU 任务进程已结束
集群：gpustack-rke2

1. 🔴 GPU 任务进程已结束
状态：已恢复 | 级别：信息
告警代码：GPUProcessStarted
节点：gpu-node-15
PID：9464
任务：train_bounded.py
事件：进程已结束
摘要：用户 25_wb 的任务进程 train_bounded.py 已结束
恢复时间（北京时间）：2026-10-11 15:30:00
进程运行时长：1 小时 20 分钟
提示：同任务已有新进程 PID 9500 正在运行，本条"已结束"对应上一个进程（PID 9464）；紧随其后的"已开始"通知属于新进程，两条消息请以 PID 区分。
```

模型实例加载：

```text
【GPU 告警·已触发】GPUStack 模型实例已加载
集群：gpustack-rke2

1. GPUStack 模型实例已加载
状态：已触发 | 级别：信息
告警代码：GPUStackModelInstanceLoaded
模型：qwen3.5-0.8b
模型实例：qwen3.5-0.8b-u3xgp
事件：资源已分配
摘要：GPUStack 模型实例 qwen3.5-0.8b-u3xgp 已加载
详情：模型 qwen3.5-0.8b 已使用 vLLM 加载到 gpu-node-15，GPUStack 已确认该模型处于运行状态。收到恢复通知表示实例已卸载、模型已停止或资源已释放。
触发时间（北京时间）：2026-10-11 15:00:00
```

## 关键设计决策与踩坑记录

复现或改造这套方案时，这几条是最容易踩的坑，也是本方案的核心经验：

1. **模型实例告警要加"真在跑"门控。** GPUStack Worker 在模型停止后仍会保留
   `gpustack:num_requests_running=0` 的残留序列，仅凭"序列存在"判断实例已加载会
   永远误报。`GPUStackModelInstanceLoaded` 叠加了 Server 端
   `gpustack:model_running_instances >= 1` 门控：模型真正启动才开始告警，停止后
   恢复。
2. **连续任务的开始/结束消息要能一眼区分。** 任务结束后立刻启动下一个任务时，
   旧 PID 的 resolved 与新 PID 的 firing 几乎同时到达、内容几乎相同。适配器用
   `【GPU 任务·开始 🟢】/【GPU 任务·结束 🔴】/【GPU 任务·切换 🔄】`横幅区分
   事件类型，并在结束消息里实时查询 Prometheus：同任务已有新进程在跑时附上
   "接续提示"（指出新旧 PID 的对应关系）。
3. **k8s 整卡分配与真实利用率是两个视角。** `nvidia.com/gpu` 只反映 k8s 分配，
   宿主机上直接跑的进程对调度器不可见。dcgm-exporter 的 `pod!=""` 归属标签 +
   gpu-process-exporter 的宿主机进程采集补齐了第二个视角，`GPUHostUseUnattributed`
   负责发现"逻辑空闲、实际满载"。
4. **归属靠标签约定。** GPU Job/Pod 携带 `observability.gpustack.io/owner|team|
   project|task` 标签，kube-state-metrics 的 `metricLabelsAllowlist` 与 dcgm 的
   `podLabelAllowlistRegex` 把标签复制进时间序列，告警消息才能点出"负责人"。
   宿主机进程按系统用户与脚本名自动归属；完整命令行参数故意不采集（可能含密钥）。
5. **凭证一律走 Secret，绝不进 Git。** 飞书 webhook URL 与签名密钥存放在
   `feishu-gpu-alerts` Secret，适配器运行时注入；管理员 kubeconfig 不进任何仓库。
6. **采集器缓存兜底。** gpu-process-exporter 内置 60 秒结果缓存（`CACHE_TTL`），
   采集失败时返回上一次成功数据并把 `gpu_process_exporter_scrape_success` 置 0，
   由 `GPUProcessExporterDown` 告警兜底，避免指标抖动造成生命周期误报。

## 验证

```bash
./verify.sh          # 部署体检：节点/Pod/CR 状态
```

```bash
# 本地打开三个 UI
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
```

常用 PromQL 与故障排查见 [docs/04-验证与运维.md](docs/04-验证与运维.md)。

## 版本

- kube-prometheus-stack `92.1.1`（Helm）
- dcgm-exporter `4.8.4`（Helm）
- GPUStack v2.2.3（集群已有）
- 适配器：`python:3.12-alpine` 直接运行 ConfigMap 里的 `adapter.py`，无额外依赖

文档记录时间：2026-10-11。
