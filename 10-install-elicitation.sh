#!/bin/bash

# Sets up the URL-mode OAuth *elicitation* infrastructure on the Enterprise
# Agentgateway control plane AND data plane. This is the one-time setup that
# demo/p05-security-05-elicitation-github.sh assumes is already in place; the
# demo itself only creates the per-backend secret + policy and runs the flow.
#
# Why this is separate from 09-install-obo.sh:
#   09 enables RFC 8693 token exchange for OBO (p05-security-03), where the AGENT
#   calls the STS directly and the proxy only validates the resulting JWT.
#   Elicitation is different — the PROXY itself calls the STS to look up /
#   obtain the user's third-party (GitHub) token, so it needs extra wiring
#   that OBO does not:
#
#   Control plane (helm values on enterprise-agentgateway):
#     - tokenExchange.elicitation.secretName  → default OAuth app secret the
#       STS reads to build the consent URL. (GA field name; older RC charts
#       called it tokenExchange.oidc.secretName.)
#     - tokenExchange.apiValidator.validatorType=remote → so the Solo UI's
#       Keycloak-JWT calls to the /elicitations API are accepted (k8s rejects
#       them; the controller also won't start cleanly without remote here).
#     - controller.extraEnv.CALLBACK_URL → the UI URL the proxy hands back to
#       the client. Without it the proxy returns the placeholder
#       https://example.com/elicitation. NOTE: changing this restarts the
#       controller and wipes the ephemeral STS SQLite DB (pending elicitations
#       + stored tokens), so we only set it here, once.
#
#   Data plane (EnterpriseAgentgatewayParameters + Gateway.parametersRef):
#     - STS_URI=…:7777/elicitations/oauth2/token + STS_AUTH_TOKEN → tells the
#       proxy where the STS is and how to authenticate to it. WITHOUT THIS the
#       proxy returns "token exchange required but not configured".
#
#   Single STS replica (controller.replicaCount=1):
#     - The STS stores elicitations in an IN-MEMORY SQLite DB (emptyDir,
#       medium=Memory at /var/db) that is NOT shared across pods. With >1
#       replica the proxy creates the "pending" elicitation on one pod while
#       the UI lists elicitations from another, so the UI shows nothing to
#       authorize. We pin replicaCount=1 here and restore the original on
#       cleanup. (A multi-replica HA setup would need a shared/persistent DB.)
#
# Run AFTER 09-install-obo.sh (which enables the STS / tokenExchange block).
#
# Usage: 10-install-elicitation.sh [--cleanup]
#
# Docs: https://docs.solo.io/agentgateway/latest/mcp/token-exchange/elicitations/setup/

set -u

BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Kube-context confirmation + pinning.
# shellcheck source=common/kube-context.sh
source "$(cd "${SCRIPT_DIR}/common" && pwd)/kube-context.sh"
# Live OIDC discovery probe for KEYCLOAK_ISSUER — require_env only proves it is
# non-empty, which the .envrc.sample placeholder satisfies.
# shellcheck source=common/keycloak-issuer.sh
source "$(cd "${SCRIPT_DIR}/common" && pwd)/keycloak-issuer.sh"

HELM_CHART="oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway"
DEFAULT_SECRET="elicitation-oidc"   # global default OAuth app for elicitation
PARAMS_NAME="agw-params"
GATEWAY_NAME="agentgateway-proxy"

# Solo Enterprise UI (management chart) — reconfigured for Keycloak SSO so the
# elicitations view can authenticate to the STS as the logged-in user.
UI_CHART="oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management"
UI_RELEASE="management"
UI_SERVICE="solo-enterprise-ui"
FE_CLIENT="${SOLO_UI_FRONTEND_CLIENT:-solo-ui-frontend}"   # public client for the browser
BE_CLIENT="${SOLO_UI_BACKEND_CLIENT:-solo-ui-backend}"     # confidential client for the UI backend
BACKEND_SECRET="solo-enterprise-backend-secret"  # k8s secret holding the BE_CLIENT secret
# Shared Solo UI clients live in the consolidated 'solo' realm on the external
# Keycloak (keycloak/realm-agentgateway-demo.json).
BE_CLIENT_SECRET="${SOLO_UI_BACKEND_SECRET:?set SOLO_UI_BACKEND_SECRET in .envrc (see .envrc.sample)}"

usage() {
  echo -e "Usage: $0 [--cleanup]"
  echo -e "  --cleanup  Remove elicitation wiring (params + Gateway ref, reset"
  echo -e "             apiValidator to k8s, clear default elicitation secret)"
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

solo_kube_init

# SINGLE source of truth for the callback URL. This must match the port that
# demo/p05-security-05-elicitation-github.sh port-forwards the Solo UI on
# (UI_PORT, default 4000), because this script bakes the value into the
# controller's CALLBACK_URL and into the GitHub App secret's redirect_uri — the
# consent URL the proxy hands back is built from it.
#
# There used to be TWO `:=` defaults for this in this file, :8090 here and :4000
# further down. `:=` only assigns when unset, so this one always won and the
# other was dead code — leaving the installer on 8090 while the demo moved to
# 4000. Keep exactly one definition.
: "${UI_PORT:=4000}"
: "${REDIRECT_URI:=http://localhost:${UI_PORT}/age/elicitations}"

case "${1:-}" in
  --cleanup) MODE=cleanup ;;
  -h|--help) usage ;;
  "")        MODE=install ;;
  *)         usage ;;
esac

cleanup() {
  echo ""
  echo -e "${RED}Removing elicitation infrastructure...${NC}"
  if [[ -t 0 ]]; then
    read -p "Are you sure? (y/n): " -r
    case "$REPLY" in [Yy]) ;; *) echo "Cleanup canceled."; exit 0 ;; esac
  fi

  # Drop the proxy's STS wiring.
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    patch gateway "${GATEWAY_NAME}" --type=json \
    -p='[{"op":"remove","path":"/spec/infrastructure/parametersRef"}]' 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    delete enterpriseagentgatewayparameters "${PARAMS_NAME}" --ignore-not-found 2>/dev/null || true

  # Reset the control-plane elicitation bits to the OBO baseline and restore
  # the original replica count.
  helm upgrade -i enterprise-agentgateway "${HELM_CHART}" \
    -n "${AGENTGATEWAY_NAMESPACE}" --version "${AGENTGATEWAY_VERSION}" \
    --kube-context "${CLUSTER_CONTEXT}" --reuse-values \
    --set "tokenExchange.elicitation.secretName=" \
    --set tokenExchange.apiValidator.validatorType=k8s \
    --set "controller.replicaCount=${AGENTGATEWAY_CONTROLLER_REPLICAS:-1}" 2>/dev/null || true

  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    delete secret "${DEFAULT_SECRET}" --ignore-not-found 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    delete secret "${BACKEND_SECRET}" --ignore-not-found 2>/dev/null || true

  # The solo-ui clients live in the shared external realm; nothing to undo here.
  echo -e "${GREEN}Cleanup complete.${NC}"
  exit 0
}

require_env AGENTGATEWAY_VERSION AGENTGATEWAY_NAMESPACE CLUSTER_CONTEXT \
            KEYCLOAK_JWKS_URL

[ "$MODE" = "cleanup" ] && cleanup

# GitHub creds are demo-specific. When they're absent (e.g. a base install by
# someone who hasn't registered a GitHub App), skip rather than fail — this
# keeps install-all.sh going. The elicitation demo can be wired later by
# re-running this script once GITHUB_CLIENT_ID/SECRET are exported.
if [ -z "${GITHUB_CLIENT_ID:-}" ] || [ -z "${GITHUB_CLIENT_SECRET:-}" ]; then
  echo -e "${YELLOW}Skipping elicitation infra: GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET not set.${NC}"
  echo -e "${YELLOW}Register a GitHub App, export both, and re-run this script to enable${NC}"
  echo -e "${YELLOW}demo/p05-security-05-elicitation-github.sh.${NC}"
  exit 0
fi

# SSO reconfig needs these too. (The agw-ui clients are defined in the realm
# JSON now, so no Keycloak admin/kcadm access is required here.)
require_env KEYCLOAK_ISSUER UI_MANAGEMENT_VERSION

# Fail fast on a bad/placeholder issuer. Deliberately AFTER the cleanup
# gate above — a teardown must not require Keycloak to be reachable.
solo_verify_keycloak_issuer

echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Installing URL-mode OAuth elicitation infrastructure${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"

# The UI is reached over a localhost port-forward (./ui-login.sh), so the OAuth
# callback / consent URL is REDIRECT_URI from .envrc (localhost). It MUST match
# the GitHub App's Authorization callback URL.
echo -e "   ${GREEN}REDIRECT_URI:${NC} ${REDIRECT_URI}"
echo -e "   ${YELLOW}The GitHub App's Authorization callback URL MUST equal this.${NC}"

echo -e "${BLUE}1. Creating the default elicitation OAuth secret (${DEFAULT_SECRET})...${NC}"
echo -e "   ${YELLOW}redirect_uri: ${REDIRECT_URI}${NC}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  create secret generic "${DEFAULT_SECRET}" \
    --from-literal=type=oauth \
    --from-literal=title="GitHub" \
    --from-literal=client_id="${GITHUB_CLIENT_ID}" \
    --from-literal=client_secret="${GITHUB_CLIENT_SECRET}" \
    --from-literal=app_id=github \
    --from-literal=authorize_url=https://github.com/login/oauth/authorize \
    --from-literal=access_token_url=https://github.com/login/oauth/access_token \
    --from-literal=scopes="read:user repo" \
    --from-literal=redirect_uri="${REDIRECT_URI}" \
    --dry-run=client -o yaml \
  | kubectl --context "${CLUSTER_CONTEXT}" apply -f -

echo -e "${BLUE}2. Configuring control plane (elicitation secret + apiValidator=remote + CALLBACK_URL + single replica)...${NC}"
echo -e "   ${YELLOW}Note: setting CALLBACK_URL re-rolls the controller and wipes the STS SQLite DB.${NC}"
echo -e "   ${YELLOW}Pinning controller.replicaCount=1 (in-memory STS DB isn't shared across pods).${NC}"
# --reuse-values keeps the tokenExchange block 09-install-obo.sh established
# (issuer, subjectValidator, actorValidator) and the license; we layer the
# elicitation-specific keys on top.
helm upgrade -i enterprise-agentgateway "${HELM_CHART}" \
  -n "${AGENTGATEWAY_NAMESPACE}" --version "${AGENTGATEWAY_VERSION}" \
  --kube-context "${CLUSTER_CONTEXT}" --reuse-values \
  --set tokenExchange.enabled=true \
  --set "tokenExchange.elicitation.secretName=${DEFAULT_SECRET}" \
  --set tokenExchange.apiValidator.validatorType=remote \
  --set "tokenExchange.apiValidator.remoteConfig.url=${KEYCLOAK_JWKS_URL}" \
  --set "controller.extraEnv.CALLBACK_URL=${REDIRECT_URI}" \
  --set controller.replicaCount=1

echo -e "${BLUE}   Waiting for control plane to re-roll...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  rollout status deploy/enterprise-agentgateway --timeout=300s

echo -e "${BLUE}3. Wiring the data plane to the STS (EnterpriseAgentgatewayParameters)...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f - <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata:
  name: ${PARAMS_NAME}
  namespace: ${AGENTGATEWAY_NAMESPACE}
spec:
  env:
    - name: STS_URI
      value: http://enterprise-agentgateway.${AGENTGATEWAY_NAMESPACE}.svc.cluster.local:7777/elicitations/oauth2/token
    - name: STS_AUTH_TOKEN
      value: /var/run/secrets/xds-tokens/xds-token
EOF

echo -e "${BLUE}   Pointing the Gateway at the parameters...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  patch gateway "${GATEWAY_NAME}" --type=merge -p "{\"spec\":{\"infrastructure\":{\"parametersRef\":{\"group\":\"enterpriseagentgateway.solo.io\",\"kind\":\"EnterpriseAgentgatewayParameters\",\"name\":\"${PARAMS_NAME}\"}}}}"

echo -e "${BLUE}   Waiting for the proxy to re-roll with STS config...${NC}"
sleep 5
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  rollout status deploy/"${GATEWAY_NAME}" --timeout=180s

echo -e "${BLUE}4. Mirroring the ${BE_CLIENT} secret into ${BACKEND_SECRET}...${NC}"
# The solo-ui-frontend/-backend OIDC clients live in the shared realm JSON
# (keycloak/realm-agentgateway-demo.json), so they're always present on the
# external Keycloak — no kcadm creation, and a UI reinstall (new LB IP) doesn't
# break them (their redirect URIs are wildcards). We only need to make
# the UI backend's client secret available to it as a k8s secret; the value is
# the fixed secret baked into the realm JSON.
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  create secret generic "${BACKEND_SECRET}" \
    --from-literal=clientSecret="${BE_CLIENT_SECRET}" \
    --dry-run=client -o yaml | kubectl --context "${CLUSTER_CONTEXT}" apply -f -

echo -e "${BLUE}5. Reconfiguring the UI for Keycloak SSO (oidc.issuer + agw-ui clients)...${NC}"
echo -e "   ${YELLOW}issuer: ${KEYCLOAK_ISSUER}${NC}"
# The chart's default role-mapper CEL is "claims.Groups.transformList(...)",
# but the agentgateway Keycloak realm doesn't emit a Groups claim, so
# GetCurrentUser fails with "no such key: Groups" and the UI shows
# "error fetching data from the server". Make the mapper tolerate a missing
# Groups claim by defaulting authenticated users to Admin (it still honors
# Groups → role mapping when the claim IS present). Passed via -f because the
# CEL contains commas/brackets that `--set` would mangle.
UI_VALUES="$(mktemp)"
cat > "${UI_VALUES}" <<'EOF'
rbac:
  roleMapping:
    roleMapper: "has(claims.Groups) ? claims.Groups.transformList(i, v, v in rolesMap, rolesMap[v]) : ['global.Admin']"
EOF
helm upgrade -i "${UI_RELEASE}" "${UI_CHART}" \
  -n "${AGENTGATEWAY_NAMESPACE}" --version "${UI_MANAGEMENT_VERSION}" \
  --kube-context "${CLUSTER_CONTEXT}" --reuse-values \
  -f "${UI_VALUES}" \
  --set "oidc.issuer=${KEYCLOAK_ISSUER}" \
  --set "ui.backend.oidc.clientId=${BE_CLIENT}" \
  --set "ui.backend.oidc.secretRef=${BACKEND_SECRET}" \
  --set "ui.backend.oidc.secretKey=clientSecret" \
  --set "ui.frontend.oidc.clientId=${FE_CLIENT}"
rm -f "${UI_VALUES}"
# roleMapper lands in a ConfigMap that doesn't checksum into the Deployment, so
# a values-only change won't restart the pod — force it so the new config and
# OIDC settings are picked up.
echo -e "${BLUE}   Restarting the UI to pick up SSO + role-mapping config...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  rollout restart deploy/"${UI_SERVICE}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  rollout status deploy/"${UI_SERVICE}" --timeout=240s

echo ""
echo -e "${GREEN}Elicitation infrastructure installed.${NC}"
echo -e "${GREEN}  Default OAuth secret:${NC} ${DEFAULT_SECRET} (per-backend override via EnterpriseAgentgatewayPolicy)"
echo -e "${GREEN}  Proxy STS endpoint:${NC}  …:7777/elicitations/oauth2/token"
echo -e "${GREEN}  Keycloak issuer:${NC}     ${KEYCLOAK_ISSUER}"
echo -e "${GREEN}  UI SSO clients:${NC}      ${FE_CLIENT} (frontend), ${BE_CLIENT} (backend)"
echo -e "${GREEN}  Callback / UI URL:${NC}   ${REDIRECT_URI}"
echo ""
# UI base URL derived from REDIRECT_URI (scheme + host:port, drop the path). The
# UI is reached over the localhost port-forward (see ui-login.sh); the SPA serves
# the agentgateway product at /age/.
_ui_rest="${REDIRECT_URI#*://}"
UI_BASE="${REDIRECT_URI%%://*}://${_ui_rest%%/*}"
echo -e "${YELLOW}ACTION REQUIRED:${NC} set the GitHub App's Authorization callback URL to:"
echo -e "    ${REDIRECT_URI}"
echo -e "and log into the UI (${UI_BASE}/age/) as a Keycloak user (e.g. bob) to"
echo -e "see + authorize elicitations."
echo ""
echo -e "${BLUE}Now run:${NC} demo/p05-security-05-elicitation-github.sh"
