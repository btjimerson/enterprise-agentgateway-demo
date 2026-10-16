#!/bin/bash

# Installs the Solo Enterprise kagent stack into the kagent namespace,
# following the quickstart
# (https://docs.solo.io/agentregistry/latest/quickstart/kagent/).
#
# Installs THREE charts (all public, oci://us-docker.pkg.dev/solo-public):
#   1. management (solo-enterprise-helm/charts/management) — UI, ClickHouse,
#      telemetry, OIDC wiring; gated behind products.{kagent,agentregistry}.
#      Versioned by UI_MANAGEMENT_VERSION (defaults to KAGENT_ENT_VERSION) — the
#      same variable the agentgateway demo uses for this chart, so a
#      co-install can pin one compatible UI version across both.
#   2. kagent-enterprise-crds — CRDs for the kagent product.
#   3. kagent-enterprise — the agent runtime controller + kagent-tools + kmcp.
# Plus:
#   - A generated RSA JWT signing secret (secret/jwt) for OBO tokens.
#   - The Role + RoleBinding that lets the agentregistry backend SA manage
#     kagent Agent CRs in this namespace.
#
# OIDC points at the external Keycloak (see ../keycloak/, the
# consolidated 'solo' realm). The kagent-backend + solo-ui-backend confidential
# client secrets come from .envrc and must match the realm import — no
# admin-API fetch, no handoff files.
#
# Usage: 02-install-kagent.sh [--cleanup]
#
# Author: Brian Jimerson

set -eu
set -o pipefail

BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared helper for co-installing this demo alongside
# enterprise-agentgateway (both use the `management` chart, which ships
# cluster-scoped CRDs that only one Helm release can own).
# shellcheck source=../common/management-crds.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/management-crds.sh"
# Kube-context confirmation + pinning.
# shellcheck source=../common/kube-context.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/kube-context.sh"
# Live OIDC discovery probe for KEYCLOAK_ISSUER — require_env only proves it is
# non-empty, which the .envrc.sample placeholder satisfies.
# shellcheck source=../common/keycloak-issuer.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/keycloak-issuer.sh"

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
  echo -e "${RED}Uninstalling kagent + management...${NC}"
  if [[ -t 0 ]]; then
    read -p "Are you sure? (y/n): " -r
    case "$REPLY" in
      [Yy]) ;;
      *) echo "Cleanup canceled."; exit 0 ;;
    esac
  fi
  kubectl --context "${CLUSTER_CONTEXT}" \
    delete -f "${SCRIPT_DIR}/manifests/kagent/rolebinding-agentregistry-writer.yaml" \
    --ignore-not-found 2>/dev/null || true
  helm uninstall kagent      -n "${KAGENT_NAMESPACE}" --kube-context "${CLUSTER_CONTEXT}" 2>/dev/null || true
  helm uninstall kagent-crds -n "${KAGENT_NAMESPACE}" --kube-context "${CLUSTER_CONTEXT}" 2>/dev/null || true
  # If the agentgateway demo's management release is still installed here,
  # don't let this uninstall delete the shared management CRDs.
  mgmt_crds_release_shared kagent-mgmt management agentgateway-system "${CLUSTER_CONTEXT}"
  helm uninstall kagent-mgmt -n "${KAGENT_NAMESPACE}" --kube-context "${CLUSTER_CONTEXT}" 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" -n "${KAGENT_NAMESPACE}" \
    delete secret jwt --ignore-not-found 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" delete namespace "${KAGENT_NAMESPACE}" \
    --ignore-not-found 2>/dev/null || true
  echo -e "${GREEN}kagent cleanup complete.${NC}"
  exit 0
}

case "${1:-}" in
  --cleanup) MODE=cleanup ;;
  -h|--help) usage ;;
  "")        MODE=install ;;
  *)         usage ;;
esac

solo_kube_init

require_env CLUSTER_CONTEXT KAGENT_NAMESPACE \
            KAGENT_LICENSE_KEY KAGENT_ENT_VERSION \
            MANAGEMENT_CHART KAGENT_CHART KAGENT_CRDS_CHART \
            OPENAI_API_KEY \
            KEYCLOAK_ISSUER KAGENT_BACKEND_CLIENT_ID KAGENT_BACKEND_SECRET \
            SOLO_UI_FRONTEND_CLIENT SOLO_UI_BACKEND_CLIENT SOLO_UI_BACKEND_SECRET

[ "$MODE" = "cleanup" ] && cleanup

# Fail fast on a bad/placeholder issuer. Deliberately AFTER the cleanup
# gate above — a teardown must not require Keycloak to be reachable.
solo_verify_keycloak_issuer

# OIDC points at the external Keycloak (consolidated 'solo' realm).
KC_ISSUER="${KEYCLOAK_ISSUER}"

# Browser-facing UI URL. The frontend builds its API calls + OIDC redirect from
# this; if empty the SPA can't start the login flow (never redirects). The UI is
# reached over a localhost port-forward, so default to that.
: "${SOLO_UI_URL:=http://localhost:4000}"

# The `management` chart (the Solo UI) is a SEPARATE artifact from the kagent
# charts and is versioned independently by the agentgateway demo as
# UI_MANAGEMENT_VERSION. Allow the same override here for cross-demo
# consistency (and co-install version matching — both share the management
# CRDs), but default to KAGENT_ENT_VERSION so kagent + UI stay in lockstep
# unless deliberately pinned. kagent-enterprise[-crds] always use KAGENT_ENT_VERSION.
: "${UI_MANAGEMENT_VERSION:=${KAGENT_ENT_VERSION}}"

echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Installing Enterprise kagent @ ${KAGENT_ENT_VERSION} + management @ ${UI_MANAGEMENT_VERSION}${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"

kubectl --context "${CLUSTER_CONTEXT}" apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${KAGENT_NAMESPACE}
EOF

# ---- 1. management chart ---------------------------------------------------
# Co-install support: if the agentgateway demo already installed a
# `management` release here, it owns the shared cluster-scoped singletons (CRDs
# + the solo-enterprise-ui ClusterRole/Binding). Steer ours to reuse the CRDs
# and use namespaced UI RBAC over our own namespaces so nothing collides on Helm
# ownership. Empty (no flags) when we're the first/only release — keeps the
# default cluster-wide UI.
# Watch only real Kubernetes namespaces the UI should see: kagent (agents) and
# agentregistry-system (registry server). NOT DEMO_APPS_NAMESPACE — that's a
# registry ORG name used by the demos, not a k8s namespace.
MGMT_WATCH_NS="${KAGENT_NAMESPACE},${AGENTREGISTRY_NAMESPACE:-agentregistry-system}"
MGMT_COINSTALL_FLAGS="$(mgmt_coinstall_flags kagent-mgmt "${CLUSTER_CONTEXT}" "${MGMT_WATCH_NS}")"
if [ -n "${MGMT_COINSTALL_FLAGS}" ]; then
  echo -e "${BLUE}  Existing management release detected — co-installing (shared CRDs + namespaced UI RBAC over: ${MGMT_WATCH_NS}).${NC}"
  # In watchNamespaces mode the chart creates namespaced UI Roles in each watched
  # namespace, which must already exist. agentregistry-system is otherwise
  # created later by step 03 — pre-create all watched namespaces (idempotent).
  for _ns in ${MGMT_WATCH_NS//,/ }; do
    kubectl --context "${CLUSTER_CONTEXT}" create namespace "${_ns}" \
      --dry-run=client -o yaml | kubectl --context "${CLUSTER_CONTEXT}" apply -f - >/dev/null
  done
fi

echo -e "${BLUE}[1/4] Installing management chart...${NC}"
# UI SSO against the external Keycloak (solo realm, solo-ui clients).
# The backend client secret is supplied via a k8s Secret (secretRef) rather than
# inline so it never lands in Helm release values. The chart's default
# role-mapper expects a Groups claim; tolerate its absence by defaulting
# authenticated users to Admin (passed via -f because the CEL has commas/
# brackets --set would mangle).
BACKEND_SECRET_NAME="solo-enterprise-backend-secret"
kubectl --context "${CLUSTER_CONTEXT}" -n "${KAGENT_NAMESPACE}" create secret generic "${BACKEND_SECRET_NAME}" \
  --from-literal=clientSecret="${SOLO_UI_BACKEND_SECRET}" \
  --dry-run=client -o yaml | kubectl --context "${CLUSTER_CONTEXT}" apply -f - >/dev/null
UI_VALUES="$(mktemp)"
cat > "${UI_VALUES}" <<'EOF'
rbac:
  roleMapping:
    roleMapper: "has(claims.Groups) ? claims.Groups.transformList(i, v, v in rolesMap, rolesMap[v]) : ['global.Admin']"
EOF

# shellcheck disable=SC2086
helm upgrade -i kagent-mgmt \
  "${MANAGEMENT_CHART}" \
  --version "${UI_MANAGEMENT_VERSION}" \
  -n "${KAGENT_NAMESPACE}" --create-namespace \
  --kube-context "${CLUSTER_CONTEXT}" \
  --values "${SCRIPT_DIR}/manifests/management/values.yaml" \
  -f "${UI_VALUES}" \
  --set cluster=mgmt-cluster \
  --set products.kagent.enabled=true \
  --set products.agentregistry.enabled=true \
  --set "rbac.mode=${UI_RBAC_MODE:-fine-grained}" \
  --set-string licensing.licenseKey="${KAGENT_LICENSE_KEY}" \
  --set-string oidc.issuer="${KC_ISSUER}" \
  --set-string ui.backend.oidc.clientId="${SOLO_UI_BACKEND_CLIENT}" \
  --set-string ui.backend.oidc.secretRef="${BACKEND_SECRET_NAME}" \
  --set-string ui.backend.oidc.secretKey=clientSecret \
  --set-string ui.frontend.oidc.clientId="${SOLO_UI_FRONTEND_CLIENT}" \
  --set-string ui.frontend.uiBackendHost="${SOLO_UI_URL}" \
  ${MGMT_COINSTALL_FLAGS} \
  --wait --timeout 10m
rm -f "${UI_VALUES}"

# ---- 2. kagent-enterprise-crds chart ---------------------------------------
echo -e "${BLUE}[2/4] Installing kagent-enterprise-crds...${NC}"
helm upgrade -i kagent-crds \
  "${KAGENT_CRDS_CHART}" \
  --version "${KAGENT_ENT_VERSION}" \
  -n "${KAGENT_NAMESPACE}" \
  --kube-context "${CLUSTER_CONTEXT}" \
  --wait --timeout 5m

# ---- 3. OBO JWT signing key (Secret/jwt) -----------------------------------
echo -e "${BLUE}[3/4] Generating OBO JWT signing key (secret/jwt)...${NC}"
JWT_PEM="$(mktemp)"
openssl genrsa -out "${JWT_PEM}" 2048 >/dev/null 2>&1
kubectl --context "${CLUSTER_CONTEXT}" -n "${KAGENT_NAMESPACE}" \
  create secret generic jwt \
  --from-file=jwt="${JWT_PEM}" \
  --dry-run=client -o yaml \
  | kubectl --context "${CLUSTER_CONTEXT}" apply -f -
rm -f "${JWT_PEM}"

# ---- 4. kagent-enterprise chart --------------------------------------------
echo -e "${BLUE}[4/4] Installing kagent-enterprise...${NC}"
helm upgrade -i kagent \
  "${KAGENT_CHART}" \
  --version "${KAGENT_ENT_VERSION}" \
  -n "${KAGENT_NAMESPACE}" \
  --kube-context "${CLUSTER_CONTEXT}" \
  --values "${SCRIPT_DIR}/manifests/kagent/values.yaml" \
  --set-string licensing.licenseKey="${KAGENT_LICENSE_KEY}" \
  --set agents.k8s-agent.enabled=true \
  --set kagent-tools.enabled=true \
  --set kmcp.licensing.createSecret=false \
  --set-string oidc.issuer="${KC_ISSUER}" \
  --set oidc.clientId="${KAGENT_BACKEND_CLIENT_ID}" \
  --set-string oidc.secret="${KAGENT_BACKEND_SECRET}" \
  --set-string providers.openAI.apiKey="${OPENAI_API_KEY}" \
  --wait --timeout 10m

# ---- 5. RoleBinding for the agentregistry backend SA -----------------------
# Lets the registry server (ServiceAccount agentregistry-enterprise in
# AGENTREGISTRY_NAMESPACE) create/update kagent Agent CRs when it deploys an
# agent to the kagent Runtime. Applied after CRDs exist.
echo -e "${BLUE}Applying Role + RoleBinding so the registry backend SA can manage kagent Agents...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply \
  -f "${SCRIPT_DIR}/manifests/kagent/rolebinding-agentregistry-writer.yaml"

echo ""
echo -e "${GREEN}kagent + management ready in namespace '${KAGENT_NAMESPACE}'.${NC}"
echo -e "${GREEN}Charts:${NC}"
echo -e "${GREEN}  kagent-mgmt   →${NC} ${MANAGEMENT_CHART}:${UI_MANAGEMENT_VERSION}"
echo -e "${GREEN}  kagent-crds   →${NC} ${KAGENT_CRDS_CHART}:${KAGENT_ENT_VERSION}"
echo -e "${GREEN}  kagent        →${NC} ${KAGENT_CHART}:${KAGENT_ENT_VERSION}"
echo -e "${GREEN}OIDC issuer:${NC}  ${KC_ISSUER}"
echo -e "${GREEN}Controller:${NC}   http://kagent-controller.${KAGENT_NAMESPACE}:8083"
echo -e "${GREEN}Next:${NC}         ./03-install-agentregistry.sh"
