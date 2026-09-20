# 从提交到外网：一份可开关的 Helmfile 清单

这是一条给开发和运维共用的链路：从 `git push` 到客户能打开 HTTPS，同时能管集群、看指标、日志、链路和剖析。不必在每台机器上散落 `helm install`。本仓用 [Helmfile](https://github.com/helmfile/helmfile) 做成开关：每个应用独立 release、独立 namespace，关掉一个不会绑死其它。

```text
git push
  → GitLab（代码仓、MR）
    → CI（GitLab CI + Runner，或 Jenkins）：构建镜像
      → 镜像仓库（GitLab Registry 或 Harbor）
        → CD（Argo CD 或 Flux）：同步到集群
          → 应用运行（PVC、数据库、队列、对象存储按需）
            → APISIX 或 Envoy Gateway（Gateway API）按域名对外
              → 可选 ExternalDNS 写公网记录
              → 外网 HTTPS
          → 集群管理（CiliKube / Headlamp）
          → 可观测（Prometheus / Grafana / VictoriaLogs / Tempo / Pyroscope / OTel）
          → 服务网格（Istio，按需）
```

Chart 本体不进 Git（`charts/platform-config` 和 `charts/flux-gitops` 除外）。其余部署时从官方 Helm / OCI 仓库和 [charts.cillian.website](https://charts.cillian.website)（CiliKube）拉取。

开关在 `values/defaults.yaml` 的 `apps.<id>.enabled`。默认装入口、存储类、集群管理和可观测；代码、CI、镜像仓库、CD 和中间件按环境打开。

GitOps 管的应用不走 Helmfile。`apps.flux2` 只装控制器，装完它还不知道看哪个仓；`fluxGitops` 补上这一步，渲染一个 GitRepository 和若干 Kustomization。仓库地址、分支、目录是每个集群自己的事，写在 `values/private.yaml`（不进 Git），格式见 `values/private.yaml.example`：

```yaml
fluxGitops:
  gitUrl: "https://gitlab.example.com/you/gitops.git"
  deployToken: ""          # 只读 token，公开仓可留空
  kustomizations:
    - name: demo
      path: ./apps/demo
      namespace: demo
      createNamespace: true
```

`fluxGitops.enabled` 需要同时开 `apps.flux2.enabled`，且 `gitUrl` 和 `kustomizations` 都不能空，否则 helmfile 直接 fail——装个只拉代码不 apply 的 Flux 没有意义。

## 组件

| 分类 | 组件 | 作用 | 默认 |
| --- | --- | --- | --- |
| 代码 | GitLab | 代码仓、MR | 关 |
| CI | GitLab CI | 随 GitLab，构建并推镜像 | 随 GitLab |
| CI | GitLab Runner | 在集群里跑 GitLab CI job；需 `gitlabUrl` + `runnerToken` | 关 |
| CI | Jenkins | 独立 CI，与 GitLab CI 二选一即可 | 关 |
| 镜像仓库 | GitLab Registry | 随 GitLab，CI 推镜像 | 随 GitLab |
| 镜像仓库 | Harbor | 独立仓库；与 GitLab Registry 二选一 | 关 |
| CD | Argo CD | 把应用同步到集群 | 关 |
| CD | Flux | 同上；不要与 Argo CD 同时当主控 | 关 |
| 流量入口 | MetalLB | 裸金属 L2 VIP，给网关 LoadBalancer | 开 |
| 流量入口 | cert-manager | 发证书；默认 ClusterIssuer `selfsigned` | 开 |
| 流量入口 | APISIX | HTTP 网关与 Ingress Controller | 开 |
| 流量入口 | Gateway API | Kubernetes Gateway / HTTPRoute CRD | 关 |
| 流量入口 | Envoy Gateway | Gateway API 的一种实现（GatewayClass `eg`） | 关 |
| 流量入口 | ExternalDNS | 把 Ingress / Service（开 Gateway API 时含 HTTPRoute）写成 DNS | 关 |
| 存储 | local-path-provisioner | 动态 PVC，设为 default StorageClass | 开 |
| 存储 | RustFS | S3 对象存储（standalone，首选） | 关 |
| 存储 | MinIO | S3 对象存储，与 RustFS 互斥 | 关 |
| 存储 | JuiceFS CSI | POSIX 文件系统，依赖 Redis + RustFS 或 MinIO | 关 |
| 中间件 | PostgreSQL | 关系数据库 | 关 |
| 中间件 | Redis | 缓存；开 JuiceFS 时必须开 | 关 |
| 中间件 | NATS | 消息队列 | 关 |
| 可观测 | kube-prometheus-stack | Prometheus、Grafana、Alertmanager | 开 |
| 可观测 | VictoriaLogs | 日志存储 | 开 |
| 可观测 | VictoriaLogs Collector | 采集节点上的容器日志 | 开 |
| 可观测 | VictoriaMetrics | 指标备选，不要与 Prometheus 同时当主刮取 | 关 |
| 可观测 | OpenTelemetry Collector | OTLP 采集（deployment 模式，带 `k8sattributes`） | 开 |
| 可观测 | Tempo | 链路 | 开 |
| 可观测 | Pyroscope | 持续剖析 | 开 |
| 可观测 | Loki | 日志备选，与 VictoriaLogs 互斥 | 关 |
| 可观测 | Beyla | eBPF 自动剖析（特权 DaemonSet） | 关 |
| 服务网格 | Istio | sidecar 网格（base + istiod）；南北流量仍走 APISIX | 关 |
| 集群管理 | metrics-server | `kubectl top` / HPA；kubeadm 与 Kind 用 `--kubelet-insecure-tls` | 开 |
| 集群管理 | CiliKube | 看节点和工作负载 | 开 |
| 集群管理 | Headlamp | 看节点和工作负载 | 开 |

业务入口默认用 Ingress，class 取 `private.yaml` 的 `ingressClass`（默认 `apisix`），证书注解 `cert-manager.io/cluster-issuer: selfsigned`（公网改 `letsencrypt-prod`）。备选是 **Gateway API**：先开 `gatewayApi`（只装 CRD）或直接开 `envoyGateway`（CRD + 控制器）。HTTPRoute 用 GatewayClass `eg`。南北流量选一个当主（APISIX 或 Envoy Gateway），不要两个一起当主入口。Istio 只做 sidecar，不提供对外 Ingress。

**Envoy Gateway 不处理 Ingress 对象**，它只实现 Gateway API。所以关掉 APISIX 时，示例 Ingress 和 Let's Encrypt 的 http01 挑战都会指向一个没人接管的 class；这种组合 helmfile 直接 fail，要么开着 APISIX，要么把 `ingressClass` 改成实际在跑的控制器。

CI 把镜像推到 **GitLab Registry** 或 **Harbor**，不要两个都当主仓库。开 Harbor 时，清单会关掉 GitLab 自带 Registry。Harbor 默认 ClusterIP（`http://harbor.harbor.svc`），需要域名时再改 Ingress。

### GitLab 的外部依赖

**chart 10.x 不再自带 PostgreSQL、Redis 和对象存储**，缺一个就连渲染都过不去。所以 `apps.gitlab.enabled: true` 之外还要：

- `gitlab.domain`：必填，GitLab 的所有 URL 由它拼出来
- 数据库和缓存：开着本仓的 `postgresql` / `redis` 就自动指向 `postgresql.<ns>.svc` 和 `redis-master.<ns>.svc`；用外部实例就填 `gitlab.psqlHost` / `gitlab.redisHost`
- **本仓不会替你建这些 Secret**，install 前先在 GitLab 的命名空间里建好（名字可在 `private.yaml` 改）：

| Secret | key | 内容 |
| --- | --- | --- |
| `gitlab-psql` | `password` | 数据库用户 `gitlab` 的口令 |
| `gitlab-redis` | `redis-password` | Redis 口令 |
| `gitlab-object-storage` | `connection` | Rails 的对象存储连接（YAML） |
| `gitlab-registry-storage` | `config` | Registry 后端配置（开 Harbor 时用不到） |
| `gitlab-s3cmd` | `config` | 备份用的 s3cmd 配置 |

数据库里的 `gitlab` 用户和 `gitlabhq_production` 库也要自己建——本仓的 `postgresql` release 是通用的，不会为 GitLab 预置。

GitLab 自带的 cert-manager 与 issuer 在 `values/apps/gitlab.yaml` 里关掉了：本仓单独装 cert-manager，ClusterIssuer 由 `charts/platform-config` 提供，两边都开会变成两个证书来源。

GitLab CI 要在集群里跑 job，还要单独开 `gitlabRunner`（只开 GitLab 不会装 Runner）。在 `private.yaml` 填 `gitlabUrl`（带 `https://`）和 `runnerToken`。token 从 GitLab 里已注册的 runner 拿，不是旧的 registration token。CoreDNS 不读节点 `/etc/hosts`。顶层 `hostAliases` 只作用在 Runner 自己的 Pod，**job Pod 要另在 `runners.config` 里写 `[[runners.kubernetes.host_aliases]]`**，否则 DinD 解析不了内网主机名。DinD 还必须在同一段里写 `privileged = true`（chart 0.89 不再认 `runners.privileged`，见 `values/apps/gitlab-runner.yaml`）。

ExternalDNS 默认关。打开后按 Ingress / Service 写 DNS；同时开了 Gateway API 或 Envoy Gateway 时会多 watch `HTTPRoute`。策略是 `upsert-only`（不删你在 DNS 控制台手工建的记录）。必须在 `private.yaml` 写 `provider`（不要用 chart 默认的 `aws`）；Cloudflare 还要 `cloudflareApiToken`。

metrics-server 默认开，给 `kubectl top` 和 HPA 用。kubeadm / Kind 上 chart overlay 带 `--kubelet-insecure-tls`。目标集群已经有 metrics-server 时，把 `metricsServer.enabled` 关掉再 apply。

可观测默认是 **指标（Prometheus）+ 日志（VictoriaLogs）+ 链路（Tempo）+ 剖析（Pyroscope）**。VictoriaLogs Collector 是 DaemonSet，把容器日志打进 VictoriaLogs（`:9428`）。链路上，OTel Collector 与 Tempo 都装在 `monitoring`（和 kube-prometheus-stack 同一个命名空间，Grafana 里指标跳链路更顺）；OTel Collector 用 **deployment 模式**，应用按 Service DNS 把 span 发给 `opentelemetry-collector.monitoring.svc:4317`（不是 daemonset 的 hostPort，应用因此不依赖本节点的 agent），Collector 再转给 Tempo —— 转发这一段是本仓在 `values/apps/opentelemetry-collector.yaml` 里显式配的 `otlp/tempo` exporter；chart 默认的 traces pipeline 只有 `debug`，不配就等于收到即丢弃。VictoriaMetrics 默认关，当作 Prometheus 的替换/备选。Loki 默认关，当作 VictoriaLogs 的替换（开 Loki 时 Promtail 会一起装，且必须关掉 VictoriaLogs）。Beyla 默认关，需要集群级 eBPF 剖析时再开。

Istio 默认关，只装控制面（istiod），不另开 Istio Ingress；对外入口默认仍是 APISIX，备选 Envoy Gateway。

RustFS 与 MinIO 不要同时开启，helmfile 会失败。JuiceFS 的 StorageClass 名是 `juicefs`；Prometheus、Tempo、对象存储自己的盘继续用 `local-path`。集群里已有 default StorageClass 时，关掉 `localPathProvisioner`。

CiliKube 公开 index 上的 chart 版本是 **1.0.0**，镜像 tag 在 `values/apps/cilikube.yaml` 为 **v1.5.0**。

## 前置

- Helm 3.16+、Helmfile 1.x（清单文件必须是 `helmfile.yaml.gotmpl`，否则 `{{ }}` 不会渲染）
- 可选：`helm plugin install https://github.com/databus23/helm-diff`
- `cp values/private.yaml.example values/private.yaml`，并填写：
  - `metallb.addresses`：节点二层网一段空闲地址，例如 `192.168.1.240-192.168.1.250`。占位 `192.168.0.0-192.168.0.0` 会让 template/apply 失败
  - CiliKube：`openssl rand -hex 16` 生成 `jwtSecret`（≥16）和 `encryptionKey`（恰好 32 字符）。CiliKube 默认开着，而它启动时会拒绝 chart 自带的占位值，所以这两项不填 helmfile 就 fail
  - 若开启 GitLab：`gitlab.domain`，以及上面「GitLab 的外部依赖」列的库、缓存和 Secret
  - 若开启 Redis / JuiceFS：`redis.password`（建议 hex）
  - 若开启 RustFS / MinIO：access/secret，不要用上游默认口令
  - 若开启 Harbor：`harbor.adminPassword`，不要用 `Harbor12345`
  - 若开启 GitLab Runner：`gitlabRunner.gitlabUrl`（带协议）和 `gitlabRunner.runnerToken`（GitLab 里已注册 runner 的 token，不是旧 registration token）
  - 若开启 ExternalDNS：`externalDns.provider`（例如 `cloudflare`）；Cloudflare 还要填 `cloudflareApiToken`，可选 `domainFilters` / `txtOwnerId`

面向空集群。目标集群里已有同名 Helm release 时，不要用默认开关直接 apply（会升级或冲突）；把某项改为 `enabled: false` 再 apply 会卸载已有 release。

## 安装

```bash
git clone <this-repo>
cd platform-stack
cp values/private.yaml.example values/private.yaml
# 至少填 metallb.addresses 和 CiliKube 的 jwtSecret / encryptionKey，
# 否则 template / apply 会带着具体缺哪一项的提示直接失败
# 需要提交即部署：打开 gitlab（GitLab CI + Registry）+ gitlabRunner，或 jenkins + harbor，以及 argoCd 或 flux2
./scripts/apply.sh
```

网关地址：

```bash
kubectl -n apisix get svc apisix-gateway
```

公网 Let's Encrypt（VIP 的 80 端口须从互联网可达，且已填写 `letsencrypt.email`）：

```bash
./scripts/apply.sh --state-values-file values/letsencrypt.yaml
```

把 CiliKube / Grafana 挂到网关：`exampleIngress.enabled: true`，并在 `private.yaml` 写入 `hosts.cilikube` / `hosts.grafana`。

没有域名时可以 port-forward：

```bash
kubectl -n cilikube port-forward svc/cilikube-frontend 8088:80
kubectl -n cilikube port-forward svc/cilikube-backend 8080:8080
kubectl -n headlamp port-forward svc/headlamp 4466:80
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Kind（无 L2 VIP：关闭 MetalLB 和 local-path，APISIX 使用 NodePort）：

```bash
./scripts/apply.sh -e kind
./scripts/apply.sh -e kind --state-values-set kindMirror=true
```

## 升级

```yaml
# values/defaults.yaml
apps:
  argoCd:
    enabled: true
  rustfs:
    enabled: true
  redis:
    enabled: true
  juicefsCsi:
    enabled: true
  minio:
    enabled: false
```

```bash
./scripts/bump.sh          # 对照上游只打印，不改文件
./scripts/diff.sh         # 或 helmfile template
# 改 version 后再
./scripts/apply.sh
```
