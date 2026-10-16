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
#   Data plane (spec.env on the agw-params EnterpriseAgentgatewayParameters, which
#   01-install-agentgateway.sh creates and the Gateway already references):
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
# The infrastructure above is provider-neutral. It is installed when EITHER
# GitHub credentials are set (the legacy default Secret, used by
# demo/p05-security-05-elicitation-github.sh) OR --with-atlassian is passed.
# With neither, the script skips itself so a base install never wires elicitation.
#
# --with-atlassian additionally stands up Atlassian's remote MCP server behind
# the gateway at /atlassian, using the TYPED policy fields:
#   - registers a client with Atlassian's MCP OAuth server through dynamic client
#     registration (idempotent: an existing client for the same redirect URI is
#     reused) and stores it in the atlassian-mcp-oauth Secret,
#   - applies manifests/backend-atlassian-mcp.yaml, httproute-mcp-atlassian.yaml
#     and policy-elicitation-atlassian.yaml.
# Atlassian cannot use oauthTokenExchange (its token endpoint rejects every
# subject_token_type), and a developer-console OAuth 2.0 (3LO) token is not
# accepted by mcp.atlassian.com, so no pre-registered Atlassian app is needed.
#
# Usage: 10-install-elicitation.sh [--with-atlassian] [--cleanup]
#
# Required env vars (see .envrc.sample):
#   AGENTGATEWAY_VERSION, AGENTGATEWAY_NAMESPACE, CLUSTER_CONTEXT,
#   KEYCLOAK_JWKS_URL, KEYCLOAK_ISSUER, UI_MANAGEMENT_VERSION
# Optional:
#   GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET   enable the GitHub default Secret
#   REDIRECT_URI                             UI elicitations page (default below)
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
# shellcheck source=../common/kube-context.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/kube-context.sh"
# Live OIDC discovery probe for KEYCLOAK_ISSUER — require_env only proves it is
# non-empty, which the .envrc.sample placeholder satisfies.
# shellcheck source=../common/keycloak-issuer.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/keycloak-issuer.sh"

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
# Keycloak (../keycloak/realm-demo.json).
BE_CLIENT_SECRET="${SOLO_UI_BACKEND_SECRET:?set SOLO_UI_BACKEND_SECRET in .envrc (see .envrc.sample)}"

usage() {
  echo -e "Usage: $0 [--with-atlassian] [--cleanup]"
  echo -e "  --with-atlassian  Also register a client with Atlassian's MCP OAuth server and"
  echo -e "                    expose Atlassian's remote MCP server at /atlassian (typed policy)"
  echo -e "  --cleanup         Remove elicitation wiring (STS env on agw-params, reset"
  echo -e "                    apiValidator to k8s, clear default elicitation secret, remove"
  echo -e "                    the Atlassian backend/route/policy/secret)"
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

MODE=install
WITH_ATLASSIAN=0
for arg in "$@"; do
  case "${arg}" in
    --cleanup)        MODE=cleanup ;;
    --with-atlassian) WITH_ATLASSIAN=1 ;;
    -h|--help)        usage ;;
    *)                usage ;;
  esac
done

MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
ATLASSIAN_SECRET="atlassian-mcp-oauth"
# Atlassian publishes its MCP OAuth endpoints (authorize, token, registration) here.
ATLASSIAN_DISCOVERY="https://mcp.atlassian.com/.well-known/oauth-authorization-server"

cleanup() {
  echo ""
  echo -e "${RED}Removing elicitation infrastructure...${NC}"
  if [[ -t 0 ]]; then
    read -p "Are you sure? (y/n): " -r
    case "$REPLY" in [Yy]) ;; *) echo "Cleanup canceled."; exit 0 ;; esac
  fi

  # The Atlassian demo objects go first: the policy references the Secret.
  for m in policy-elicitation-atlassian httproute-mcp-atlassian backend-atlassian-mcp; do
    kubectl --context "${CLUSTER_CONTEXT}" delete \
      -f "${MANIFESTS_DIR}/${m}.yaml" --ignore-not-found 2>/dev/null || true
  done
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    delete secret "${ATLASSIAN_SECRET}" --ignore-not-found 2>/dev/null || true

  # Drop the proxy's STS wiring. agw-params itself stays: it carries the model
  # cost catalog and is owned by 01-install-agentgateway.sh.
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    patch enterpriseagentgatewayparameters "${PARAMS_NAME}" --type=json \
    -p='[{"op":"remove","path":"/spec/env"}]' 2>/dev/null || true

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

# Provider credentials are demo-specific. With none configured (e.g. a base
# install by someone who hasn't registered a GitHub App and didn't ask for
# Atlassian), skip rather than fail — this keeps install-all.sh going. Wire it
# later by re-running with GITHUB_CLIENT_ID/SECRET exported, or --with-atlassian.
HAVE_GITHUB=0
if [ -n "${GITHUB_CLIENT_ID:-}" ] && [ -n "${GITHUB_CLIENT_SECRET:-}" ]; then
  HAVE_GITHUB=1
fi
if [ "${HAVE_GITHUB}" = "0" ] && [ "${WITH_ATLASSIAN}" = "0" ]; then
  echo -e "${YELLOW}Skipping elicitation infra: GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET not set and --with-atlassian not given.${NC}"
  echo -e "${YELLOW}Register a GitHub App, export both, and re-run this script to enable${NC}"
  echo -e "${YELLOW}demo/p05-security-05-elicitation-github.sh, or run it with --with-atlassian.${NC}"
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

if [ "${HAVE_GITHUB}" = "1" ]; then
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
else
  echo -e "${BLUE}1. Skipping the default GitHub elicitation secret (no GITHUB_CLIENT_ID/SECRET).${NC}"
fi

echo -e "${BLUE}2. Configuring control plane (apiValidator=remote + CALLBACK_URL + single replica)...${NC}"
echo -e "   ${YELLOW}Note: setting CALLBACK_URL re-rolls the controller and wipes the STS SQLite DB.${NC}"
echo -e "   ${YELLOW}Pinning controller.replicaCount=1 (in-memory STS DB isn't shared across pods).${NC}"
# --reuse-values keeps the tokenExchange block 09-install-obo.sh established
# (issuer, subjectValidator, actorValidator) and the license; we layer the
# elicitation-specific keys on top. The first element is a harmless, always-set
# value so the array is never empty (bash 3.2 + set -u).
HELM_SETS=(--set tokenExchange.enabled=true)
# The legacy global default Secret is mutually exclusive with the typed
# entElicitation field on a given backend, and only meaningful with GitHub.
if [ "${HAVE_GITHUB}" = "1" ]; then
  HELM_SETS+=(--set "tokenExchange.elicitation.secretName=${DEFAULT_SECRET}")
fi
helm upgrade -i enterprise-agentgateway "${HELM_CHART}" \
  -n "${AGENTGATEWAY_NAMESPACE}" --version "${AGENTGATEWAY_VERSION}" \
  --kube-context "${CLUSTER_CONTEXT}" --reuse-values \
  "${HELM_SETS[@]}" \
  --set tokenExchange.apiValidator.validatorType=remote \
  --set "tokenExchange.apiValidator.remoteConfig.url=${KEYCLOAK_JWKS_URL}" \
  --set "controller.extraEnv.CALLBACK_URL=${REDIRECT_URI}" \
  --set controller.replicaCount=1

echo -e "${BLUE}   Waiting for control plane to re-roll...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  rollout status deploy/enterprise-agentgateway --timeout=300s

echo -e "${BLUE}3. Wiring the data plane to the STS (EnterpriseAgentgatewayParameters)...${NC}"
# agw-params and the Gateway's parametersRef belong to 01-install-agentgateway.sh
# (they carry the model cost catalog). Merge-patch the STS env in; a
# `kubectl apply` of a spec holding only env would prune modelCatalog.
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  patch enterpriseagentgatewayparameters "${PARAMS_NAME}" --type=merge -p "$(cat <<JSON
{"spec":{"env":[
  {"name":"STS_URI","value":"http://enterprise-agentgateway.${AGENTGATEWAY_NAMESPACE}.svc.cluster.local:7777/elicitations/oauth2/token"},
  {"name":"STS_AUTH_TOKEN","value":"/var/run/secrets/xds-tokens/xds-token"}
]}}
JSON
)"

echo -e "${BLUE}   Waiting for the proxy to re-roll with STS config...${NC}"
sleep 5
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  rollout status deploy/"${GATEWAY_NAME}" --timeout=180s

echo -e "${BLUE}4. Mirroring the ${BE_CLIENT} secret into ${BACKEND_SECRET}...${NC}"
# The solo-ui-frontend/-backend OIDC clients live in the shared realm JSON
# (../keycloak/realm-demo.json), so they're always present on the
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

# UI base URL derived from REDIRECT_URI (scheme + host:port, drop the path). The
# UI is reached over the localhost port-forward (see ui-login.sh); the SPA serves
# the agentgateway product at /age/.
_ui_rest="${REDIRECT_URI#*://}"
UI_BASE="${REDIRECT_URI%%://*}://${_ui_rest%%/*}"

# Atlassian MCP behind the gateway, using the typed entElicitation policy.
install_atlassian() {
  echo ""
  echo -e "${BLUE}6. Atlassian MCP: typed entElicitation policy...${NC}"

  # entTokenExchange is what injects the stored token. A chart that predates it
  # would accept the policy's entElicitation half and then silently send the
  # caller's IdP JWT upstream, so check the installed CRD rather than assuming.
  if ! kubectl --context "${CLUSTER_CONTEXT}" get crd \
      enterpriseagentgatewaypolicies.enterpriseagentgateway.solo.io -o json 2>/dev/null \
    | jq -e '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.backend.properties | has("entTokenExchange")' \
      >/dev/null 2>&1; then
    echo -e "${RED}ERROR: the installed EnterpriseAgentgatewayPolicy CRD has no backend.entTokenExchange.${NC}" >&2
    echo -e "${RED}       Upgrade the enterprise-agentgateway chart (AGENTGATEWAY_VERSION) first.${NC}" >&2
    exit 1
  fi

  local disc reg existing_id existing_redirect resp
  disc=$(curl -fsS --max-time 20 "${ATLASSIAN_DISCOVERY}") || {
    echo -e "${RED}ERROR: could not fetch ${ATLASSIAN_DISCOVERY}${NC}" >&2; exit 1; }
  ATLASSIAN_AUTHORIZE_URL=$(printf '%s' "${disc}" | jq -r '.authorization_endpoint // empty')
  ATLASSIAN_TOKEN_URL=$(printf '%s' "${disc}" | jq -r '.token_endpoint // empty')
  reg=$(printf '%s' "${disc}" | jq -r '.registration_endpoint // empty')
  if [ -z "${ATLASSIAN_AUTHORIZE_URL}" ] || [ -z "${ATLASSIAN_TOKEN_URL}" ] || [ -z "${reg}" ]; then
    echo -e "${RED}ERROR: Atlassian's discovery document lacks an authorize/token/registration endpoint.${NC}" >&2
    exit 1
  fi
  echo -e "   authorize: ${ATLASSIAN_AUTHORIZE_URL}"
  echo -e "   token:     ${ATLASSIAN_TOKEN_URL}"

  # Reuse the registered client when the redirect URI is unchanged, so a re-run
  # does not mint a fresh client (and a fresh secret) every time.
  existing_id=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    get secret "${ATLASSIAN_SECRET}" -o jsonpath='{.data.client_id}' 2>/dev/null | base64 -d 2>/dev/null || true)
  existing_redirect=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    get secret "${ATLASSIAN_SECRET}" -o jsonpath='{.data.redirect_uri}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [ -n "${existing_id}" ] && [ "${existing_redirect}" = "${REDIRECT_URI}" ]; then
    ATLASSIAN_CLIENT_ID="${existing_id}"
    echo -e "   ${GREEN}Reusing the registered Atlassian client${NC} (${ATLASSIAN_SECRET}, redirect ${REDIRECT_URI})"
  else
    echo -e "   Registering a client with Atlassian (redirect ${REDIRECT_URI})..."
    resp=$(curl -fsS --max-time 30 -X POST "${reg}" -H 'Content-Type: application/json' \
      -d "$(jq -n --arg r "${REDIRECT_URI}" '{
            client_name: "agentgateway elicitation",
            redirect_uris: [$r],
            grant_types: ["authorization_code", "refresh_token"],
            response_types: ["code"],
            token_endpoint_auth_method: "client_secret_basic"}')") || {
      echo -e "${RED}ERROR: Atlassian client registration failed.${NC}" >&2; exit 1; }
    ATLASSIAN_CLIENT_ID=$(printf '%s' "${resp}" | jq -r '.client_id // empty')
    _secret=$(printf '%s' "${resp}" | jq -r '.client_secret // empty')
    if [ -z "${ATLASSIAN_CLIENT_ID}" ] || [ -z "${_secret}" ]; then
      echo -e "${RED}ERROR: Atlassian's registration response had no client_id/client_secret.${NC}" >&2
      exit 1
    fi
    kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
      create secret generic "${ATLASSIAN_SECRET}" \
        --from-literal=client_id="${ATLASSIAN_CLIENT_ID}" \
        --from-literal=client_secret="${_secret}" \
        --from-literal=redirect_uri="${REDIRECT_URI}" \
        --dry-run=client -o yaml \
      | kubectl --context "${CLUSTER_CONTEXT}" apply -f -
    unset _secret
  fi

  export ATLASSIAN_CLIENT_ID ATLASSIAN_AUTHORIZE_URL ATLASSIAN_TOKEN_URL REDIRECT_URI
  kubectl --context "${CLUSTER_CONTEXT}" apply -f "${MANIFESTS_DIR}/backend-atlassian-mcp.yaml"
  kubectl --context "${CLUSTER_CONTEXT}" apply -f "${MANIFESTS_DIR}/httproute-mcp-atlassian.yaml"
  # shellcheck disable=SC2016  # the single quotes are envsubst's allow-list, not an expansion
  envsubst '${ATLASSIAN_CLIENT_ID} ${ATLASSIAN_AUTHORIZE_URL} ${ATLASSIAN_TOKEN_URL} ${REDIRECT_URI}' \
    < "${MANIFESTS_DIR}/policy-elicitation-atlassian.yaml" \
    | kubectl --context "${CLUSTER_CONTEXT}" apply -f -

  # A policy that reports Accepted can still be unattached; wait for both.
  echo -e "   Waiting for the policy to be Accepted and Attached..."
  for _ in $(seq 1 30); do
    if kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
        get enterpriseagentgatewaypolicy atlassian-elicitation -o json 2>/dev/null \
      | jq -e '[.status.ancestors[0].conditions[]? | select(.status == "True") | .type]
               | (index("Accepted") != null) and (index("Attached") != null)' >/dev/null 2>&1; then
      echo -e "   ${GREEN}Policy atlassian-elicitation is Accepted and Attached.${NC}"
      return 0
    fi
    sleep 2
  done
  echo -e "${RED}ERROR: policy atlassian-elicitation is not Accepted+Attached after 60s:${NC}" >&2
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    get enterpriseagentgatewaypolicy atlassian-elicitation -o jsonpath='{.status}' >&2; echo >&2
  exit 1
}

if [ "${WITH_ATLASSIAN}" = "1" ]; then
  install_atlassian
fi

echo ""
echo -e "${GREEN}Elicitation infrastructure installed.${NC}"
if [ "${HAVE_GITHUB}" = "1" ]; then
  echo -e "${GREEN}  Default OAuth secret:${NC} ${DEFAULT_SECRET} (per-backend override via EnterpriseAgentgatewayPolicy)"
fi
echo -e "${GREEN}  Proxy STS endpoint:${NC}  …:7777/elicitations/oauth2/token"
echo -e "${GREEN}  Keycloak issuer:${NC}     ${KEYCLOAK_ISSUER}"
echo -e "${GREEN}  UI SSO clients:${NC}      ${FE_CLIENT} (frontend), ${BE_CLIENT} (backend)"
echo -e "${GREEN}  Callback / UI URL:${NC}   ${REDIRECT_URI}"
echo ""

if [ "${HAVE_GITHUB}" = "1" ]; then
  echo -e "${YELLOW}ACTION REQUIRED (GitHub):${NC} set the GitHub App's Authorization callback URL to:"
  echo -e "    ${REDIRECT_URI}"
  echo -e "and log into the UI (${UI_BASE}/age/) as a Keycloak user (e.g. bob) to"
  echo -e "see + authorize elicitations."
  echo -e "${BLUE}Then run:${NC} demo/p05-security-05-elicitation-github.sh"
  echo ""
fi

if [ "${WITH_ATLASSIAN}" = "1" ]; then
  _ui_port="${_ui_rest%%/*}"; _ui_port="${_ui_port##*:}"
  echo -e "${BLUE}Start the Atlassian elicitation${NC} (three steps; the same Keycloak user must sign in to the UI):"
  echo -e "  1. Leave this running in a second terminal:"
  echo -e "       kubectl --context ${CLUSTER_CONTEXT} -n ${AGENTGATEWAY_NAMESPACE} port-forward deploy/${UI_SERVICE} ${_ui_port}:8090"
  echo -e "  2. Get a JWT and make the first call. It fails with the consent URL in the error:"
  cat <<EOF
       JWT=\$(curl -s -d client_id=${KEYCLOAK_CLIENT_ID:-agw-client} -d grant_type=password \\
         -d username="\${DEMO_USER_BOB:-bob}" -d password="\${DEMO_USER_BOB_PASSWORD}" \\
         ${KEYCLOAK_ISSUER}/protocol/openid-connect/token | jq -r .access_token)
       GW=\$(kubectl --context ${CLUSTER_CONTEXT} -n ${AGENTGATEWAY_NAMESPACE} get svc ${GATEWAY_NAME} \\
         -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}:{.spec.ports[0].port}')
       curl -s -X POST "http://\${GW}/atlassian" -H "Authorization: Bearer \${JWT}" \\
         -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \\
         -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'
EOF
  echo -e "  3. Open ${REDIRECT_URI} , sign in as the same user, and approve the pending Atlassian"
  echo -e "     item. Repeat the curl above: it now returns the MCP initialize result."
  echo -e "${YELLOW}To start over for every user:${NC} restart the controller (it drops all stored tokens):"
  echo -e "       kubectl --context ${CLUSTER_CONTEXT} -n ${AGENTGATEWAY_NAMESPACE} rollout restart deploy/enterprise-agentgateway"
fi
