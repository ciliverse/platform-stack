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
| CI | GitLab Runner | 在集群里跑 GitLab CI job；需 `gitlabUrl` + `runnerToken` | 开 |
| CI | Jenkins | 独立 CI，与 GitLab CI 二选一即可 | 开 |
| 镜像仓库 | GitLab Registry | 随 GitLab，CI 推镜像 | 随 GitLab |
| 镜像仓库 | Harbor | 独立仓库；与 GitLab Registry 二选一 | 关 |
| CD | Argo CD | 把应用同步到集群 | 开 |
| CD | Flux（community chart） | 同上；不要与 Argo CD 同时当主控 | 开 |
| CD | Flux Operator | 官方 bootstrap 方式之一，与上一行互斥 | 关 |
| 流量入口 | MetalLB | 裸金属 L2 VIP，给网关 LoadBalancer | 开 |
| 流量入口 | cert-manager | 发证书；ClusterIssuer `selfsigned`，可选 `local-ca`、`letsencrypt-prod` | 开 |
| 流量入口 | APISIX | HTTP/HTTPS 网关与 Ingress Controller | 开 |
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
| 可观测 | 告警转发 | Alertmanager → 飞书机器人；填了 `alerting.lark.webhookUrl` 才渲染 | 随地址 |
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

业务入口默认用 Ingress，class 取 `private.yaml` 的 `ingressClass`（默认 `apisix`），证书注解 `cert-manager.io/cluster-issuer: selfsigned`（公网改 `letsencrypt-prod`）。

**域名解析到内网地址时，ACME 签不出证书**：Let's Encrypt 要从公网访问 `http://<域名>/.well-known/...` 做 http01 校验，指向 `192.168.x.x` 的记录它连不上；dns01 则要求 DNS 托管商有对应的 cert-manager webhook。这种情况打开 `localCa.enabled`：`platform-config` 会用 `selfsigned` 签一张自签根证书，再建一个从它签发的 `local-ca` ClusterIssuer。Ingress 注解写 `cert-manager.io/cluster-issuer: local-ca`，客户端**导入一次根证书**，之后这个 issuer 签的所有域名都受信任。导出根证书：

```bash
kubectl get secret local-ca-tls -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > local-ca.crt
```

**网关要自己打开 HTTPS 监听**：apisix chart 的 `apisix.ssl.enabled` 默认是 `false`，此时 Ingress 里的 `tls:` 块会被正常接受、证书也会签出来，但 443 根本没人监听。本仓 `values/apps/apisix.yaml` 已经打开它并把 Service 的 `tls.servicePort` 设成 443。备选是 **Gateway API**：先开 `gatewayApi`（只装 CRD）或直接开 `envoyGateway`（CRD + 控制器）。HTTPRoute 用 GatewayClass `eg`。南北流量选一个当主（APISIX 或 Envoy Gateway），不要两个一起当主入口。Istio 只做 sidecar，不提供对外 Ingress。

**APISIX ingress controller 2.x 还需要一个 `GatewayProxy`**：控制器自己不知道该把路由写给哪个数据面，缺了它 Ingress 会被 reconcile 然后丢掉，网关对所有域名回 `404 Route Not Found`，日志里只有一句 `no GatewayProxy configs provided`。`charts/platform-config` 的 `apisixGatewayProxy`（默认关）负责建这个对象；apisix chart 建出来的 IngressClass 没有 `parameters`，还要按模板注释里的 `kubectl patch` 指到该 GatewayProxy。

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

RustFS 与 MinIO 不要同时开启，helmfile 会失败。JuiceFS 的 StorageClass 名是 `juicefs`；其余组件的 PVC **都不写 `storageClassName`**，落在集群的 default StorageClass 上。集群里已经有 default StorageClass 时（比如 OpenEBS 的 `openebs-hostpath`），在 `private.yaml` 里关掉 `localPathProvisioner`，否则会多出第二套 hostpath provisioner。

Prometheus 与 Tempo 本仓**没有配 persistence**，用的是 chart 默认的 emptyDir：Pod 一重建历史数据就没了。要留存得自己加 `persistence`。

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

`EXTERNAL-IP` 就是 MetalLB 从 `metallb.addresses` 里分的 VIP，域名解析到它即可省掉 NodePort 端口号。两点容易卡住：

- 地址段要在节点**二层可达**的那张网卡所在子网里，并且从 DHCP 池里排除掉，否则 VIP 分得出来却没人应答 ARP
- 节点是虚机时，宿主机虚拟交换机的混杂模式 / MAC 变更 / 伪传输策略可能拦掉 L2 广播，表现同样是 VIP 通不了
- MetalLB 镜像在 quay.io，拉不动就按 [`values/apps/metallb.yaml`](values/apps/metallb.yaml) 换镜像站

公网 Let's Encrypt（VIP 的 80 端口须从互联网可达，且已填写 `letsencrypt.email`）：

```bash
./scripts/apply.sh --state-values-file values/letsencrypt.yaml
```

把 CiliKube / Grafana 挂到网关：`exampleIngress.enabled: true`，并在 `private.yaml` 写入 `hosts.cilikube` / `hosts.grafana`。

Argo CD 和 Jenkins 的入口同样由 `private.yaml` 的 `hosts.argocd` / `hosts.jenkins` 决定：**填了就渲染 Ingress，留空就只有 ClusterIP**，需要时 port-forward。证书注解自动取当前可用的 issuer（`letsencrypt.enabled` → `letsencrypt-prod`，否则 `localCa.enabled` → `local-ca`，再否则 `selfsigned`）。这两个 chart 各有一处必须配合网关：

- Argo CD 开了 `configs.params.server.insecure`。网关终结 TLS 后转发的是明文 HTTP，不关这个开关，`argocd-server` 会把它重定向回 HTTPS，浏览器一直转圈。
- Jenkins 的 `controller.jenkinsUrl` 指向对外域名，否则它生成的绝对链接会用集群内的 Service 名。chart 默认不渲染 Ingress 的 `path`，这里显式写了 `/` 与 `Prefix`。

Jenkins 还开了 `controller.initializeOnce`。它的 init 容器每次启动都去下载整份插件清单，集群启动早于出网链路时下载失败，init 退出——而插件目录是 emptyDir，重试时上一轮的文件还在，`cp -i` 于是逐个问"要覆盖吗"，从此卡死在那里。打开这个开关后，JENKINS_HOME 里有 `initialization-completed` 就整段跳过。代价是改 `installPlugins` 不再自动生效，需要删掉那个标记文件让 init 重跑一次。

没有域名时可以 port-forward：

```bash
kubectl -n cilikube port-forward svc/cilikube-frontend 8088:80
kubectl -n cilikube port-forward svc/cilikube-backend 8080:8080
kubectl -n headlamp port-forward svc/headlamp 4466:80
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

### 告警发到飞书

`kube-prometheus-stack` 装完就有几十组告警规则在跑，但 chart 默认的 receivers 列表里**只有一个叫 `null` 的**——告警正常产生、正常路由，然后进黑洞。在群里建一个自定义机器人，把地址填进 `private.yaml`：

```yaml
alerting:
  lark:
    enabled: true
    webhookUrl: "https://open.feishu.cn/open-apis/bot/v2/hook/..."
    signSecret: ""          # 机器人开了签名校验才填
```

地址为空时**不会**给 Alertmanager 配这条路由，免得告警发给一个没人监听的地址。

中间需要一个转换器，因为 **Alertmanager 不能给 webhook 套模板**：它发出去的 JSON 结构是固定的，而机器人只认自己那套 `{"msg_type": ...}`。`platform-config` 会渲染一个很小的转换服务——一段不依赖三方库的 Python 放在 ConfigMap 里，跑在官方 python 镜像上，不引第三方镜像。

路由里 `Watchdog` 单独留给 `null`：它按设计永远在 firing，用来证明告警链路本身活着，不该推送。其余全部转发，`send_resolved` 打开，所以恢复时会收到一张绿色卡片。

验证不需要等真实故障，往 Alertmanager 塞一条就行：

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
curl -XPOST http://127.0.0.1:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[{
  "labels":{"alertname":"PipelineTest","severity":"warning"},
  "annotations":{"summary":"告警链路联调"},
  "startsAt":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}]'
kubectl -n monitoring logs -l app=alert-lark --tail=5    # 转换器会打印机器人的原始响应
```

分组等待 30 秒，约 5 分钟后自动转 resolved 再来一张绿卡。

### Flux 怎么装

Flux 要装的是两样东西：**控制器**，和**「该同步哪个仓库的哪个目录」这个指针**。控制器装好而没有指针，它就坐在那儿什么也不干。本仓库提供三种装法，因为上游推荐的那种和「helmfile 管一切平台组件」这个模型是有张力的。

上游的原话是 *“The recommended way of installing Flux on Kubernetes clusters is by using the bootstrap procedure.”* 官方认可的 bootstrap 有三种实现：`flux bootstrap` CLI、Terraform provider、Flux Operator。而 `fluxcd-community/flux2` 这个 Helm chart 被归在 **Dev install（for testing purposes）**下面，并注明由社区 best effort 维护、不保证发版节奏。

| 开关 | 装什么 | 指针在哪 | 说明 |
| --- | --- | --- | --- |
| `apps.flux2` | community chart 装 6 个控制器 | 需配合 `fluxGitops` | 开箱最省事，但上游把它算作 dev install |
| `apps.fluxOperator` | operator 本身 | `FluxInstance` 对象 | 官方 bootstrap 方式之一；本仓库**不渲染** `FluxInstance` |
| （不用开关） | `flux bootstrap` 自己装 | Git 仓库里，Flux 自管 | 官方首推；此时两个开关都要关 |

`apps.flux2` 和 `apps.fluxOperator` 同时打开会直接 fail：两者往同一个命名空间装同一批控制器。

走 `flux2` 时，指针由 `flux-gitops` 声明，在 `private.yaml` 里配：

```yaml
fluxGitops:
  enabled: true
  sourceName: gitops
  gitUrl: "http://gitlab.example.com/OWNER/gitops.git"
  branch: main
  deployToken: "<read_repository 的 token>"   # 公开仓留空则不建 Secret
  kustomizations:
    - name: demo
      path: ./apps/demo
```

走 operator 或 bootstrap 时**不要**开 `fluxGitops`：指针改由 `FluxInstance` 或 bootstrap 提交的清单描述，两边都声明会抢同一个对象。

不管走哪条，边界都是同一条：**helmfile 管平台组件，Flux 管业务应用**。业务应用不要写进本仓库的 helmfile，而要写进 Flux 看的那个仓库；反过来那个仓库里也不要再放一份指向自己的 Kustomization。手工 `kubectl apply` 出 GitRepository 和 Kustomization 当然也能跑，但集群重建时这层接线不会跟着回来——控制器装回来了，却不知道去哪同步。

#### 从 flux2 换到 bootstrap 或 operator

**先把 GitRepository / Kustomization 备份出来再动。**`helm uninstall flux2` 会带走 chart 装的那批 CRD，而删 CRD 等于删掉集群里所有该类型的对象——正在同步的 GitRepository、Kustomization、HelmRelease 全部消失，连带它们 `prune` 过的工作负载。

```bash
kubectl get gitrepository,kustomization,helmrelease -A -o yaml > flux-objects.yaml
```

Flux Operator 支持接管已有安装，上游写了迁移指南；`flux bootstrap` 在控制器已存在时会做升级而不是重装。无论哪种，先备份再动手。

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

`bump.sh` 提示 headlamp 可以升到 0.40.x 时**跳过这一档**：那几个 chart 会给应用传 `-session-ttl`，而对应的 v0.40.1 二进制不认这个 flag，容器在解析参数时就退出。0.45.0 的二进制认，所以 pin 在 0.45.0。

kube-prometheus-stack 跨大版本升级时，**Helm 不会更新 CRD**，新 operator 会拿旧 schema 去 reconcile。chart 自带的 `crds.upgradeJob` 用 pre-upgrade hook 补这一刀，本仓已经打开（还带 `forceConflicts`，因为集群里的 CRD 归最早创建它的 field manager 所有）。

## 命名约定

发布名就是应用名，命名空间同名，一个应用一个命名空间。两处例外都有原因：`metrics-server` 属于集群插件，跟上游一样放 `kube-system`；`jenkins` 在 `cicd`，因为 JENKINS_HOME 是 PVC，换命名空间等于迁数据。

这条约定不只是整洁问题——**Helmfile 靠「发布名 + 命名空间」认领 release**。名字对不上，它既不会升级你已有的那个，也不会因为开关关着而卸掉它，而是在旁边再装一份；名字对得上而开关是关的，`apply` 就会把正在跑的卸掉。所以往已有集群接这份清单前，先用 `helm list -A` 把两边的名字和命名空间对一遍。

## 看 diff 时的一个坑

`helmfile diff` 跑的是 dry-run，而 **dry-run 里的 `lookup` 一律返回空**。不少 chart 用 `lookup` 保住自己生成的密码和证书——读得到就复用，读不到才随机生成：

```
{{- $secret := (lookup "v1" "Secret" ... ) }}
{{- if $secret }}{{ index $secret "data" "admin-password" }}
{{- else }}{{ (randAlphaNum 40) | b64enc | quote }}{{ end }}
```

于是每次 diff 都会渲染出一个新随机值，连带引用它的 Deployment / StatefulSet 上的 `checksum/*` 注解一起变，看着像要改，真 `apply` 时其实原封不动。本仓里 Grafana 的 admin 密码、Jenkins 的 admin 密码、APISIX 内置 etcd 的 jwt-token 都是这个情况。**判断方法：看到「Secret 内容变了 + 对应 workload 的 checksum 注解变了」这对组合，先去 chart 里搜一下 `lookup`，别当成漂移去追。**
