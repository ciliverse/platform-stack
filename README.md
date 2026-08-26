# Helmfile 集群应用清单

官方 Helm Chart 的开关清单：仓里只放 `helmfile.yaml.gotmpl`、覆盖 values 和包装脚本。Chart 本体部署时再拉。

自研 Ciliverse Chart 不在这里（`ciliverse-charts` / `/root/charts`）。

## 默认开启

| 应用 | namespace |
| --- | --- |
| kube-prometheus-stack | `monitoring` |
| opentelemetry-collector | `observability` |
| tempo | `observability` |
| headlamp | `headlamp` |

默认关闭：Argo CD、Flux、GitLab、Jenkins、PostgreSQL、Redis。  
GitLab 若已经装在别处，不要在这里再设一个会冲突的 hostname。

## 前置

- Helm 3.16+
- [Helmfile](https://github.com/helmfile/helmfile) 1.x（清单文件是 `helmfile.yaml.gotmpl`，否则 `{{ }}` 不会渲染）
- 可选：`helm plugin install https://github.com/databus23/helm-diff`（`./scripts/diff.sh` 需要）

## 新集群

```bash
git clone <this-repo>
cd platform-stack
# 按需改 values/defaults.yaml 的 enabled / version
./scripts/apply.sh
# 等价：helmfile apply
```

Kind / 小集群（关 Grafana、缩短 Prometheus 保留）：

```bash
./scripts/apply.sh -e kind
# 镜像加速：
./scripts/apply.sh -e kind --state-values-set kindMirror=true
```

## 开关与升级

改 `values/defaults.yaml`：

```yaml
apps:
  headlamp:
    enabled: false   # 再 apply 会跳过；集群里已有则卸载
```

看上游是否有新版本（只打印，不改文件）：

```bash
./scripts/bump.sh
```

改 `version` 后再 `./scripts/apply.sh`。

预览：

```bash
./scripts/diff.sh
# 或
helmfile template
```

密钥放 `values/private.yaml`（已 gitignore）。需要时：

```bash
helmfile apply --state-values-file values/private.yaml
```
