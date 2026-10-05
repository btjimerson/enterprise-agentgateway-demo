#!/bin/bash

# Installs the observability stack for the agentgateway demo:
#   - OpenTelemetry Collector (deployment mode)
#   - Prometheus
#   - Grafana, preloaded with:
#       * the official Agentgateway dashboard from the Solo docs
#       * a supplementary "Tokens / Cost / Latency" dashboard inline
#
# This script does NOT call ../common/monitoring-install.sh because that script is
# Istio-specific (loads gnetId 7645 / 7639 / etc.). Here we want only
# agentgateway dashboards.
#
# Usage: 03-install-observability.sh [--cleanup]
#
# Author: Brian Jimerson

set -u

BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Kube-context confirmation + pinning.
# shellcheck source=common/kube-context.sh
source "$(cd "${SCRIPT_DIR}/common" && pwd)/kube-context.sh"

# Official Agentgateway Grafana dashboard (control-plane + data-plane), VENDORED.
#
# This used to be fetched by URL from the upstream docs site. Upstream deleted it
# from main/latest (it survives only under versioned doc dirs), so the fetch
# started returning 404 while the install carried on regardless — leaving an empty
# `Agentgateway` folder and a p07 demo pointing at a dashboard that didn't exist
#. Vendored so a docs reshuffle can't silently break the demo again.
# Provenance + refresh instructions: manifests/grafana/README.md
AGW_DASHBOARD_JSON="${SCRIPT_DIR}/manifests/grafana/agentgateway-dashboard.json"

usage() { echo -e "Usage: $0 [--cleanup]"; exit 1; }

require_env() {
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then
      echo -e "${RED}ERROR: $v is not set. Source your .envrc first.${NC}" >&2
      exit 1
    fi
  done
}

cleanup() {
  echo ""
  echo -e "${RED}Uninstalling observability stack from ${OBSERVABILITY_NAMESPACE}...${NC}"
  if [[ -t 0 ]]; then
    read -p "Are you sure? (y/n): " -r
    case "$REPLY" in
      [Yy]) ;;
      *) echo "Cleanup canceled."; exit 0 ;;
    esac
  fi

  for rel in grafana prometheus opentelemetry-collector; do
    helm uninstall "${rel}" -n "${OBSERVABILITY_NAMESPACE}" \
      --kube-context "${CLUSTER_CONTEXT}" 2>/dev/null || true
  done
  kubectl --context "${CLUSTER_CONTEXT}" -n "${OBSERVABILITY_NAMESPACE}" \
    delete configmap agentgateway-scrape-config agentgateway-tokens-dashboard \
    agentgateway-official-dashboard \
    --ignore-not-found 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" delete namespace "${OBSERVABILITY_NAMESPACE}" \
    --ignore-not-found 2>/dev/null || true
  echo -e "${GREEN}Cleanup complete.${NC}"
  exit 0
}

case "${1:-}" in
  --cleanup) MODE=cleanup ;;
  -h|--help) usage ;;
  "")        MODE=install ;;
  *)         usage ;;
esac

solo_kube_init

require_env OBSERVABILITY_NAMESPACE AGENTGATEWAY_NAMESPACE CLUSTER_CONTEXT

[ "$MODE" = "cleanup" ] && cleanup

echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Installing observability stack (agentgateway dashboards)${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"

kubectl --context "${CLUSTER_CONTEXT}" create namespace "${OBSERVABILITY_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl --context "${CLUSTER_CONTEXT}" apply -f -

echo -e "${BLUE}Adding Helm repositories...${NC}"
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update open-telemetry prometheus-community grafana >/dev/null

echo -e "${BLUE}Installing OpenTelemetry Collector (deployment mode)...${NC}"
helm upgrade -i opentelemetry-collector open-telemetry/opentelemetry-collector \
  --namespace "${OBSERVABILITY_NAMESPACE}" \
  --kube-context "${CLUSTER_CONTEXT}" \
  --set mode=deployment \
  --set image.repository=otel/opentelemetry-collector-contrib \
  --set config.exporters.prometheus.endpoint="0.0.0.0:8889" \
  --set config.service.pipelines.metrics.exporters[0]=prometheus \
  --set ports.prometheus.enabled=true \
  --set ports.prometheus.containerPort=8889 \
  --set ports.prometheus.servicePort=8889 \
  --set ports.prometheus.protocol=TCP

kubectl --context "${CLUSTER_CONTEXT}" -n "${OBSERVABILITY_NAMESPACE}" \
  rollout status deployment/opentelemetry-collector --timeout=180s

if [ -z "${PROMETHEUS_URL:-}" ]; then
  echo -e "${BLUE}Installing Prometheus...${NC}"
  helm upgrade -i prometheus prometheus-community/prometheus \
    --namespace "${OBSERVABILITY_NAMESPACE}" \
    --kube-context "${CLUSTER_CONTEXT}" \
    --set server.persistentVolume.enabled=false \
    --set alertmanager.enabled=false
  kubectl --context "${CLUSTER_CONTEXT}" -n "${OBSERVABILITY_NAMESPACE}" \
    rollout status deployment/prometheus-server --timeout=300s
  PROMETHEUS_URL="http://prometheus-server.${OBSERVABILITY_NAMESPACE}.svc.cluster.local"
else
  echo -e "${BLUE}Skipping Prometheus install; using external datasource: ${PROMETHEUS_URL}${NC}"
fi

echo -e "${BLUE}Installing Grafana with agentgateway dashboard...${NC}"
# Fail loudly if the vendored dashboard is missing or unparseable. The previous
# URL-fetch version failed silently: a 404 produced an empty Agentgateway folder
# with no error anywhere, so the install looked fine and only broke mid-demo.
if [ ! -s "${AGW_DASHBOARD_JSON}" ]; then
  echo -e "${RED}ERROR: vendored dashboard missing or empty:${NC}" >&2
  echo "  ${AGW_DASHBOARD_JSON}" >&2
  echo "  See manifests/grafana/README.md to restore it." >&2
  exit 1
fi
if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${AGW_DASHBOARD_JSON}" 2>/dev/null; then
  echo -e "${RED}ERROR: ${AGW_DASHBOARD_JSON} is not valid JSON.${NC}" >&2
  echo "  Grafana would silently skip it, leaving the Agentgateway folder empty." >&2
  exit 1
fi

# Both dashboards load through the SIDECAR provider (label grafana_dashboard=1),
# and sidecar.dashboards.provider.folder puts them in the SAME Grafana folder.
# Previously the official dashboard used the chart's URL provider with
# folder=Agentgateway while the sidecar provider had folder='' — which is why the
# tokens dashboard landed in General while the Agentgateway folder sat empty.
helm upgrade -i grafana grafana/grafana \
  --namespace "${OBSERVABILITY_NAMESPACE}" \
  --kube-context "${CLUSTER_CONTEXT}" \
  --set persistence.enabled=false \
  --set adminPassword=admin \
  --set "datasources.datasources\\.yaml.apiVersion=1" \
  --set "datasources.datasources\\.yaml.datasources[0].name=Prometheus" \
  --set "datasources.datasources\\.yaml.datasources[0].type=prometheus" \
  --set "datasources.datasources\\.yaml.datasources[0].url=${PROMETHEUS_URL}" \
  --set "datasources.datasources\\.yaml.datasources[0].access=proxy" \
  --set "datasources.datasources\\.yaml.datasources[0].isDefault=true" \
  --set "sidecar.dashboards.enabled=true" \
  --set "sidecar.dashboards.label=grafana_dashboard" \
  --set "sidecar.dashboards.folder=/tmp/dashboards" \
  --set "sidecar.dashboards.provider.folder=Agentgateway" \
  --set "sidecar.dashboards.searchNamespace=${OBSERVABILITY_NAMESPACE}"

kubectl --context "${CLUSTER_CONTEXT}" -n "${OBSERVABILITY_NAMESPACE}" \
  rollout status deployment/grafana --timeout=300s

echo ""
echo -e "${BLUE}Loading the official Agentgateway dashboard (vendored)...${NC}"
# --from-file keys the entry by filename, which is what the sidecar expects.
kubectl --context "${CLUSTER_CONTEXT}" -n "${OBSERVABILITY_NAMESPACE}" \
  create configmap agentgateway-official-dashboard \
  --from-file=agentgateway.json="${AGW_DASHBOARD_JSON}" \
  --dry-run=client -o yaml \
  | kubectl --context "${CLUSTER_CONTEXT}" label --local -f - \
      grafana_dashboard=1 --dry-run=client -o yaml \
  | kubectl --context "${CLUSTER_CONTEXT}" apply -f -

echo ""
echo -e "${BLUE}Adding Prometheus scrape config for agentgateway (control plane + proxies)...${NC}"
cat <<EOF | kubectl --context "${CLUSTER_CONTEXT}" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: agentgateway-scrape-config
  namespace: ${OBSERVABILITY_NAMESPACE}
  labels:
    app: agentgateway-scrape
data:
  extra-scrape-configs.yaml: |
    - job_name: agentgateway-control-plane
      kubernetes_sd_configs:
        - role: pod
          namespaces:
            names: [${AGENTGATEWAY_NAMESPACE}]
      relabel_configs:
        - source_labels: [__meta_kubernetes_pod_label_app]
          regex: enterprise-agentgateway
          action: keep
        - source_labels: [__meta_kubernetes_pod_container_port_number]
          regex: "9092"
          action: keep
    - job_name: agentgateway-data-plane
      kubernetes_sd_configs:
        - role: pod
          namespaces:
            names: [${AGENTGATEWAY_NAMESPACE}]
      relabel_configs:
        - source_labels: [__meta_kubernetes_pod_label_gateway_networking_k8s_io_gateway_name]
          regex: agentgateway-proxy
          action: keep
EOF

echo -e "${BLUE}Adding supplementary Tokens/Cost/Latency dashboard via sidecar ConfigMap...${NC}"
cat <<'EOF' | kubectl --context "${CLUSTER_CONTEXT}" apply -n "${OBSERVABILITY_NAMESPACE}" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: agentgateway-tokens-dashboard
  labels:
    grafana_dashboard: "1"
data:
  agentgateway-tokens.json: |
    {
      "title": "Agentgateway — Tokens, Cost, Latency",
      "uid": "agentgateway-tokens",
      "schemaVersion": 38,
      "timezone": "",
      "tags": ["agentgateway"],
      "panels": [
        {
          "type": "stat",
          "title": "Input tokens (5m rate)",
          "targets": [{"expr": "sum(rate(agentgateway_gen_ai_client_token_usage_sum{gen_ai_token_type=\"input\"}[5m]))"}],
          "gridPos": {"h":4,"w":6,"x":0,"y":0}
        },
        {
          "type": "stat",
          "title": "Output tokens (5m rate)",
          "targets": [{"expr": "sum(rate(agentgateway_gen_ai_client_token_usage_sum{gen_ai_token_type=\"output\"}[5m]))"}],
          "gridPos": {"h":4,"w":6,"x":6,"y":0}
        },
        {
          "type": "stat",
          "title": "MCP requests (5m rate)",
          "targets": [{"expr": "sum(rate(agentgateway_mcp_requests_total[5m]))"}],
          "gridPos": {"h":4,"w":6,"x":12,"y":0}
        },
        {
          "type": "stat",
          "title": "Error ratio (5m)",
          "targets": [{"expr": "sum(rate(agentgateway_requests_total{status=~\"4..|5..\"}[5m])) / sum(rate(agentgateway_requests_total[5m]))"}],
          "fieldConfig": {"defaults": {"unit": "percentunit"}},
          "gridPos": {"h":4,"w":6,"x":18,"y":0}
        },
        {
          "type": "timeseries",
          "title": "Requests by provider (per sec, 5m avg)",
          "targets": [{"expr": "sum by (gen_ai_system) (rate(agentgateway_gen_ai_server_request_duration_count[5m]))", "legendFormat": "{{gen_ai_system}}"}],
          "fieldConfig": {"defaults": {"unit": "reqps"}},
          "gridPos": {"h":8,"w":12,"x":0,"y":4}
        },
        {
          "type": "timeseries",
          "title": "LLM latency p95 by provider",
          "targets": [{"expr": "histogram_quantile(0.95, sum by (gen_ai_system, le) (rate(agentgateway_gen_ai_server_request_duration_bucket[5m])))"}],
          "fieldConfig": {"defaults": {"unit": "s"}},
          "gridPos": {"h":8,"w":12,"x":12,"y":4}
        },
        {
          "type": "timeseries",
          "title": "Guardrail actions",
          "targets": [{"expr": "sum by (phase, action) (rate(agentgateway_guardrail_checks_total[5m]))", "legendFormat": "{{phase}} / {{action}}"}],
          "gridPos": {"h":8,"w":12,"x":0,"y":12}
        },
        {
          "type": "timeseries",
          "title": "HTTP request duration p95 by route",
          "targets": [{"expr": "histogram_quantile(0.95, sum by (route, le) (rate(agentgateway_request_duration_seconds_bucket[5m])))", "legendFormat": "{{route}}"}],
          "fieldConfig": {"defaults": {"unit": "s"}},
          "gridPos": {"h":8,"w":12,"x":12,"y":12}
        },
        {
          "type": "timeseries",
          "title": "Retries by status/reason",
          "targets": [{"expr": "sum by (status, reason) (rate(agentgateway_retries_total[5m]))", "legendFormat": "{{status}} / {{reason}}"}],
          "gridPos": {"h":8,"w":12,"x":0,"y":20}
        },
        {
          "type": "timeseries",
          "title": "Requests by status code",
          "targets": [{"expr": "sum by (status, route) (rate(agentgateway_requests_total[5m]))", "legendFormat": "{{route}} · {{status}}"}],
          "gridPos": {"h":8,"w":12,"x":12,"y":20}
        }
      ]
    }
EOF

echo ""
echo -e "${GREEN}Observability stack installed.${NC}"
echo -e "${GREEN}Grafana port-forward:${NC}"
echo -e "  kubectl --context ${CLUSTER_CONTEXT} -n ${OBSERVABILITY_NAMESPACE} port-forward svc/grafana 3000:80"
echo -e "${GREEN}Login:${NC} admin / admin"
echo -e "${GREEN}Dashboards${NC} (both in the ${GREEN}Agentgateway${NC} folder):"
echo -e "  - Agentgateway (official, vendored from manifests/grafana/)"
echo -e "  - Agentgateway — Tokens, Cost, Latency (supplementary)"
echo ""
echo -e "${BLUE}Prometheus picks up agentgateway metrics automatically via the default${NC}"
echo -e "${BLUE}kubernetes-pods job + pod annotations from the enterprise-agentgateway chart.${NC}"
echo -e "${BLUE}The ${OBSERVABILITY_NAMESPACE}/agentgateway-scrape-config ConfigMap is kept for${NC}"
echo -e "${BLUE}reference in case you later migrate to kube-prometheus-stack ServiceMonitors.${NC}"
