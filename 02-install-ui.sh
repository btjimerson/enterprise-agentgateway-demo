#!/bin/bash

# Installs the Solo Enterprise UI for Agentgateway.
#
# The UI ships in a SEPARATE Helm chart — `management` under the Solo
# Enterprise Helm registry. It deploys:
#   - solo-enterprise-ui              (the UI frontend)
#   - solo-enterprise-telemetry-collector (OTel collector for traces)
#   - management-clickhouse-shard0-0   (trace storage)
#
# After install, an EnterpriseAgentgatewayPolicy named "tracing" is applied
# so the data-plane proxy sends traces into the collector.
#
# Ref: https://docs.solo.io/agentgateway/2.3.x/install/ui/setup/
#
# Usage: 02-install-ui.sh [--cleanup]
#
# Author: Brian Jimerson

set -eu
set -o pipefail

BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared helper for co-installing alongside another release of the `management`
# chart (it ships cluster-scoped CRDs that only one Helm release can own).
# shellcheck source=common/management-crds.sh
source "$(cd "${SCRIPT_DIR}/common" && pwd)/management-crds.sh"
# Kube-context confirmation + pinning.
# shellcheck source=common/kube-context.sh
source "$(cd "${SCRIPT_DIR}/common" && pwd)/kube-context.sh"
# Live OIDC discovery probe for KEYCLOAK_ISSUER — require_env only proves it is
# non-empty, which the .envrc.sample placeholder satisfies.
# shellcheck source=common/keycloak-issuer.sh
source "$(cd "${SCRIPT_DIR}/common" && pwd)/keycloak-issuer.sh"

usage() {
  echo -e "Usage: $0 [--cleanup]"
  exit 1
}

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
  echo -e "${RED}Uninstalling Solo Enterprise UI (management chart) + tracing policy.${NC}"
  if [[ -t 0 ]]; then
    read -p "Are you sure? (y/n): " -r
    case "$REPLY" in
      [Yy]) ;;
      *) echo "Cleanup canceled."; exit 0 ;;
    esac
  fi

  kubectl --context "${CLUSTER_CONTEXT}" delete \
    -f "${SCRIPT_DIR}/manifests/policy-tracing.yaml" --ignore-not-found 2>/dev/null || true

  # If another management release (kagent-mgmt) is still installed here, don't
  # let this uninstall delete the shared management CRDs.
  mgmt_crds_release_shared management kagent-mgmt kagent "${CLUSTER_CONTEXT}"

  helm uninstall management -n "${AGENTGATEWAY_NAMESPACE}" \
    --kube-context "${CLUSTER_CONTEXT}" 2>/dev/null || true

  # ClickHouse PVCs are not deleted by `helm uninstall`. Remove them so a
  # re-install starts from a clean state.
  echo -e "${RED}Deleting ClickHouse PVCs...${NC}"
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    delete pvc -l app.kubernetes.io/name=clickhouse --ignore-not-found 2>/dev/null || true

  echo -e "${GREEN}UI cleanup complete.${NC}"
  exit 0
}

case "${1:-}" in
  --cleanup) MODE=cleanup ;;
  -h|--help) usage ;;
  "")        MODE=install ;;
  *)         usage ;;
esac

solo_kube_init

require_env AGENTGATEWAY_NAMESPACE CLUSTER_CONTEXT UI_MANAGEMENT_VERSION \
            UI_CLUSTER_NAME AGENTGATEWAY_LICENSE_KEY \
            KEYCLOAK_ISSUER SOLO_UI_FRONTEND_CLIENT SOLO_UI_BACKEND_CLIENT SOLO_UI_BACKEND_SECRET

# Browser-facing UI URL. The frontend builds its API calls + OIDC redirect from
# this; if empty the SPA can't start the login flow (never redirects). The UI is
# reached over a localhost port-forward (./ui-login.sh), so default to that.
: "${SOLO_UI_URL:=http://localhost:4000}"

[ "$MODE" = "cleanup" ] && cleanup

# Fail fast on a bad/placeholder issuer. Deliberately AFTER the cleanup
# gate above — a teardown must not require Keycloak to be reachable.
solo_verify_keycloak_issuer

echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Installing Solo Enterprise UI (management ${UI_MANAGEMENT_VERSION})${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"

# Co-install support: if another product already installed a
# `management` release here, it owns the shared cluster-scoped singletons (CRDs
# + the solo-enterprise-ui ClusterRole/Binding). Steer ours to reuse the CRDs
# and use namespaced UI RBAC over our own namespaces so nothing collides on Helm
# ownership. Empty (no flags) when we're the first/only release — keeps the
# default cluster-wide UI.
MGMT_WATCH_NS="${AGENTGATEWAY_NAMESPACE},${DEMO_APPS_NAMESPACE:-agentgateway-demo}"
MGMT_COINSTALL_FLAGS="$(mgmt_coinstall_flags management "${CLUSTER_CONTEXT}" "${MGMT_WATCH_NS}")"
if [ -n "${MGMT_COINSTALL_FLAGS}" ]; then
  echo -e "${BLUE}  Existing management release detected — co-installing (shared CRDs + namespaced UI RBAC over: ${MGMT_WATCH_NS}).${NC}"
  # In watchNamespaces mode the chart creates namespaced UI Roles in each watched
  # namespace, which must already exist. agentgateway-demo is otherwise created
  # later by the demo-app steps — pre-create all watched namespaces (idempotent).
  for _ns in ${MGMT_WATCH_NS//,/ }; do
    kubectl --context "${CLUSTER_CONTEXT}" create namespace "${_ns}" \
      --dry-run=client -o yaml | kubectl --context "${CLUSTER_CONTEXT}" apply -f - >/dev/null
  done
fi

# The backend secret below is applied BEFORE `helm ... --create-namespace`, so
# the namespace has to exist already. It normally does (01-install-agentgateway.sh
# creates it), but this script is also runnable on its own — ensure it here so a
# standalone UI install doesn't fail on a clean cluster. Idempotent.
kubectl --context "${CLUSTER_CONTEXT}" create namespace "${AGENTGATEWAY_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl --context "${CLUSTER_CONTEXT}" apply -f - >/dev/null

# UI SSO against the external Keycloak (solo realm, solo-ui clients).
# The chart's default role-mapper expects a Groups claim; tolerate its absence
# by defaulting authenticated users to Admin (passed via -f because the CEL has
# commas/brackets --set would mangle).
BACKEND_SECRET_NAME="solo-enterprise-backend-secret"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" create secret generic "${BACKEND_SECRET_NAME}" \
  --from-literal=clientSecret="${SOLO_UI_BACKEND_SECRET}" \
  --dry-run=client -o yaml | kubectl --context "${CLUSTER_CONTEXT}" apply -f - >/dev/null
UI_VALUES="$(mktemp)"
cat > "${UI_VALUES}" <<'EOF'
rbac:
  roleMapping:
    roleMapper: "has(claims.Groups) ? claims.Groups.transformList(i, v, v in rolesMap, rolesMap[v]) : ['global.Admin']"
EOF

# ui.backend.livenessProbe overrides — DO NOT drop these back to chart defaults.
#
# ui-backend applies its ClickHouse migrations BEFORE it binds /healthz on :8090.
# The chart's defaults (initialDelaySeconds 10 + periodSeconds 10 x failureThreshold 3)
# give that roughly 40 seconds. On a cold cluster the migration run (~76 tables in
# platformdb) overruns it, so the kubelet kills the container mid-migration and
# golang-migrate is left with a `dirty=1` row and no matching success row:
#
#   fatal  error applying ClickHouse migrations: migrating up:
#          Dirty database version 5002001. Fix and force version.
#
# That state does NOT self-heal — every restart fast-fails on the dirty check before
# doing any work, so the pod can never finish the migration that would clear the flag,
# and the install is wedged until someone forces the version by hand or drops the
# database. The loudest symptom is a red herring: the healthy k8sobjects-collector
# sidecar logs "Database platformdb does not exist" because ui-backend is what creates
# it. for the full diagnosis and the manual recovery steps.
#
# Tradeoff: a genuinely hung ui-backend now takes ~10 min to be restarted instead of
# 40 s. Correct for a demo rig — losing the schema is far worse than a slow restart.
# The chart has no startupProbe support for ui.backend at UI_MANAGEMENT_VERSION,
# which is what this actually wants; readiness is left at chart defaults and
# still gates traffic.
# shellcheck disable=SC2086
helm upgrade -i management \
  oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
  --namespace "${AGENTGATEWAY_NAMESPACE}" \
  --create-namespace \
  --version "${UI_MANAGEMENT_VERSION}" \
  --kube-context "${CLUSTER_CONTEXT}" \
  -f "${UI_VALUES}" \
  --set cluster="${UI_CLUSTER_NAME}" \
  --set products.agentgateway.enabled=true \
  --set products.agentgateway.features.cost-management=true \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
  --set "oidc.issuer=${KEYCLOAK_ISSUER}" \
  --set "ui.backend.oidc.clientId=${SOLO_UI_BACKEND_CLIENT}" \
  --set "ui.backend.oidc.secretRef=${BACKEND_SECRET_NAME}" \
  --set "ui.backend.oidc.secretKey=clientSecret" \
  --set "ui.frontend.oidc.clientId=${SOLO_UI_FRONTEND_CLIENT}" \
  --set "ui.frontend.uiBackendHost=${SOLO_UI_URL}" \
  --set ui.backend.livenessProbe.initialDelaySeconds=300 \
  --set ui.backend.livenessProbe.failureThreshold=30 \
  ${MGMT_COINSTALL_FLAGS} \
  --wait \
  --timeout 10m
rm -f "${UI_VALUES}"

echo -e "${BLUE}Waiting for any remaining UI workloads...${NC}"
# Discover deployments and statefulsets by the Helm release label instead of
# hardcoded names (names can shift between chart versions).
for d in $(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
      get deploy -l app.kubernetes.io/instance=management -o name 2>/dev/null); do
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    rollout status "$d" --timeout=300s || true
done
for s in $(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
      get statefulset -l app.kubernetes.io/instance=management -o name 2>/dev/null); do
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    rollout status "$s" --timeout=600s || true
done

echo -e "${BLUE}Applying tracing EnterpriseAgentgatewayPolicy (proxy → telemetry collector)...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply \
  -f "${SCRIPT_DIR}/manifests/policy-tracing.yaml"

echo ""
echo -e "${GREEN}Solo Enterprise UI installed.${NC}"
echo -e "${GREEN}Port-forward command:${NC}"
echo -e "  kubectl --context ${CLUSTER_CONTEXT} -n ${AGENTGATEWAY_NAMESPACE} port-forward svc/solo-enterprise-ui 4000:80"
echo -e "${GREEN}Then open:${NC} http://localhost:4000/age/"
