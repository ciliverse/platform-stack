#!/usr/bin/env bash
# Print newer chart versions than values/defaults.yaml. Does not edit files.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if ! command -v helm >/dev/null 2>&1; then
  echo "missing 'helm' in PATH." >&2
  exit 1
fi

python3 - <<'PY'
import re, subprocess, sys
from pathlib import Path

text = Path("values/defaults.yaml").read_text()
# apps.<camel>:
#   version: "x"
blocks = re.findall(
    r"  (\w+):\n(?:    .+\n)*?    version: \"([^\"]+)\"",
    text,
)
search = {
    "kubePrometheusStack": "prometheus-community/kube-prometheus-stack",
    "opentelemetryCollector": "open-telemetry/opentelemetry-collector",
    "tempo": "grafana/tempo",
    "headlamp": "headlamp/headlamp",
    "argoCd": "argo/argo-cd",
    "flux2": "fluxcd-community/flux2",
    "gitlab": "gitlab/gitlab",
    "jenkins": "jenkins/jenkins",
    "cilikube": "ciliverse/cilikube",
    "apisix": "apisix/apisix",
    "localPathProvisioner": "containeroo/local-path-provisioner",
    "metallb": "metallb/metallb",
    "certManager": "jetstack/cert-manager",
    "rustfs": "rustfs/rustfs",
    "minio": "minio/minio",
    "juicefsCsi": "juicefs/juicefs-csi-driver",
    "nats": "nats/nats",
    "harbor": "harbor/harbor",
    "gitlabRunner": "gitlab/gitlab-runner",
    "metricsServer": "metrics-server/metrics-server",
    "externalDns": "external-dns/external-dns",
    "victoriaLogs": "vm/victoria-logs-single",
    "victoriaLogsCollector": "vm/victoria-logs-collector",
    "victoriaMetrics": "vm/victoria-metrics-single",
    "loki": "grafana/loki",
    "promtail": "grafana/promtail",
    "pyroscope": "grafana/pyroscope",
    "beyla": "grafana/beyla",
    "istio": "istio/istiod",
}
oci = {
    "postgresql": "oci://registry-1.docker.io/bitnamicharts/postgresql",
    "redis": "oci://registry-1.docker.io/bitnamicharts/redis",
    "gatewayApi": "oci://docker.io/envoyproxy/gateway-crds-helm",
    "envoyGateway": "oci://docker.io/envoyproxy/gateway-helm",
}

repos = [
    ("prometheus-community", "https://prometheus-community.github.io/helm-charts"),
    ("open-telemetry", "https://open-telemetry.github.io/opentelemetry-helm-charts"),
    ("grafana", "https://grafana.github.io/helm-charts"),
    ("headlamp", "https://kubernetes-sigs.github.io/headlamp/"),
    ("argo", "https://argoproj.github.io/argo-helm"),
    ("fluxcd-community", "https://fluxcd-community.github.io/helm-charts"),
    ("gitlab", "https://charts.gitlab.io/"),
    ("jenkins", "https://charts.jenkins.io"),
    ("ciliverse", "https://charts.cillian.website"),
    ("apisix", "https://charts.apiseven.com"),
    ("containeroo", "https://charts.containeroo.ch"),
    ("metallb", "https://metallb.github.io/metallb"),
    ("jetstack", "https://charts.jetstack.io"),
    ("rustfs", "https://charts.rustfs.com"),
    ("minio", "https://charts.min.io/"),
    ("juicefs", "https://juicedata.github.io/charts/"),
    ("nats", "https://nats-io.github.io/k8s/helm/charts/"),
    ("harbor", "https://helm.goharbor.io"),
    ("vm", "https://victoriametrics.github.io/helm-charts/"),
    ("istio", "https://istio-release.storage.googleapis.com/charts"),
    ("metrics-server", "https://kubernetes-sigs.github.io/metrics-server/"),
    ("external-dns", "https://kubernetes-sigs.github.io/external-dns/"),
]
for name, url in repos:
    subprocess.run(["helm", "repo", "add", name, url], check=False, capture_output=True)
subprocess.run(["helm", "repo", "update"], check=False, capture_output=True)

print("pinned -> latest (helm search). Edit values/defaults.yaml yourself.")
for key, pinned in blocks:
    if key in oci:
        print(f"  {key:24} {pinned:16}  OCI {oci[key]}  (check: helm show chart {oci[key]})")
        continue
    chart = search.get(key)
    if not chart:
        continue
    out = subprocess.run(
        ["helm", "search", "repo", chart, "--versions", "--output", "json"],
        capture_output=True, text=True,
    )
    latest = "?"
    if out.returncode == 0 and out.stdout.strip().startswith("["):
        import json
        rows = json.loads(out.stdout)
        if rows:
            latest = rows[0].get("version", "?")
    mark = "  " if latest == pinned else "->"
    print(f"  {key:24} {pinned:16} {mark} {latest}")
PY
