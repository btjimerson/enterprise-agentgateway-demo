#!/bin/bash
# Pillar 5 · Case 5: URL-mode OAuth elicitation against GitHub MCP server.
#
# ─────────────────────────────────────────────────────────────────────
# WHY THIS PATTERN EXISTS
# ─────────────────────────────────────────────────────────────────────
# An agentic workflow needs to call a SaaS API (GitHub here, but same
# pattern for Salesforce, Google, Notion, etc.) on behalf of a specific
# user. Two naïve options both lose:
#
#   (A) Have the MCP server hold a shared client_secret for the SaaS
#       provider and broker every user's request → MCP server now
#       handles privileged credentials. If the server is compromised
#       or logs verbosely, every customer's GitHub access leaks.
#
#   (B) Ask the user to paste a personal access token into the agent's
#       config file → tokens live in chat history, agent memory, and
#       (worst case) git. Not revocable per call.
#
# Elicitation (MCP spec, URL mode) is the third path: agentgateway
# intercepts the first request, returns 500 with an elicitation URL
# pointing at the Solo Enterprise UI. The user opens the URL in a
# browser, completes a normal OAuth consent dance against the SaaS
# provider's IdP, and the resulting access token is stored in the STS
# server keyed by (userId, backend). Subsequent calls automatically
# pick up the cached token. The MCP server never sees the credential —
# agentgateway injects it into the upstream Authorization header out
# of band.
#
# Properties:
#   - SaaS credentials never transit the MCP server.
#   - The token is bound to one (user, backend) pair — different users
#     get different tokens, different backends do too.
#   - Revoking the GitHub OAuth grant invalidates the cached token on
#     the next upstream call (GitHub rejects, agentgateway re-prompts).
#   - Multi-tenant safe: agentgateway's STS is the credential vault,
#     not the MCP server, not any tenant.
#
# ─────────────────────────────────────────────────────────────────────
# FLOW DIAGRAM (printed at runtime by print_elicitation_overview)
# ─────────────────────────────────────────────────────────────────────
#
#   ① Client → agentgateway: tools/call (JWT in Authorization)
#   ② agentgateway STS: lookup token for (user, github-mcp-backend) → none
#   ③ agentgateway → client: HTTP 500 { "url": "<elicitation>", … }
#   ④ User opens elicitation URL → Solo UI → GitHub authorize page
#   ⑤ GitHub callback → STS persists access_token under (user, backend)
#   ⑥ Client retries → agentgateway injects token → GitHub MCP server
#   ⑦ MCP server proxies to GitHub API → response
#
# ─────────────────────────────────────────────────────────────────────
# Prereqs
# ─────────────────────────────────────────────────────────────────────
#   - 09-install-obo.sh has run (STS server + token exchange enabled).
#   - 10-install-elicitation.sh has run (default OAuth secret +
#     apiValidator=remote + CALLBACK_URL on the control plane, and the
#     EnterpriseAgentgatewayParameters STS wiring on the proxy). Without
#     it the proxy returns "token exchange required but not configured".
#     This script checks for it and bails with a pointer if it's missing.
#   - The Solo Enterprise UI. This script port-forwards it for you on
#     localhost:4000 (UI_PORT to override) and tears the forward down on
#     exit — no second terminal needed. To use the UI's LoadBalancer
#     instead, export SOLO_UI_URL and the script leaves it alone; then set
#     REDIRECT_URI + CALLBACK_URL to that address (re-run
#     10-install-elicitation.sh) so the consent URL the proxy returns is
#     one your browser can actually reach.
#   - You have registered a GitHub App and have its client_id +
#     client_secret. Redirect URL on the App MUST match REDIRECT_URI
#     below. Default: http://localhost:4000/age/elicitations
#     NOTE: this default moved from :8090 to :4000 when the port-forward
#     was automated — update the GitHub App's Authorization callback URL
#     to match, or GitHub rejects the consent step with redirect_uri
#     mismatch.
#       https://docs.github.com/en/apps/creating-github-apps/
#         registering-a-github-app/registering-a-github-app
#   - Export GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET before running. The
#     script reads them from the environment so we don't bake real
#     creds into manifests.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"
: "${AGENTGATEWAY_NAMESPACE:=agentgateway-system}"
: "${UI_PORT:=4000}"
: "${REDIRECT_URI:=http://localhost:${UI_PORT}/age/elicitations}"

# Elicitation needs control-plane + data-plane infrastructure that is set up
# ONCE by 10-install-elicitation.sh (NOT by 09-install-obo.sh): the default
# OAuth secret + apiValidator=remote + CALLBACK_URL on the control plane, and
# the EnterpriseAgentgatewayParameters (STS_URI) + Gateway.parametersRef on
# the data plane. Without the proxy's STS_URI the gateway returns
# "token exchange required but not configured" instead of a consent URL.
# This demo only does the per-run, per-backend bits and checks the infra is
# present up front. See:
#   https://docs.solo.io/agentgateway/latest/mcp/token-exchange/elicitations/setup/

# policy-jwt is gateway-wide JWT authentication. The elicitation flow
# keys the stored credential by (userId, backend), and that userId comes
# from the validated JWT `sub`. Without this policy applied, agentgateway
# never authenticates bob's token, the STS has no user to key on, and the
# 500-elicitation-URL handshake can't happen. 09-install-obo.sh only
# enables tokenExchange on the control plane — it does NOT apply this
# gateway policy, so the demo must apply it itself (same as every other
# security/RBAC demo) and revert it on exit.
POLICY_JWT="${MANIFESTS_DIR}/policy-jwt.yaml"
BACKEND="${MANIFESTS_DIR}/agentgatewaybackend-github-mcp.yaml"
ROUTE="${MANIFESTS_DIR}/httproute-mcp-github.yaml"
POLICY="${MANIFESTS_DIR}/policy-elicitation-github.yaml"
SECRET_NAME="elicitation-oidc-github"

# Verify the one-time elicitation infrastructure (10-install-elicitation.sh)
# is in place. We check the data-plane wiring specifically, since a missing
# Gateway parametersRef is what produces the confusing
# "token exchange required but not configured" runtime error.
require_elicitation_infra() {
  local ref
  ref=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    get gateway agentgateway-proxy \
    -o jsonpath='{.spec.infrastructure.parametersRef.name}' 2>/dev/null || true)
  if [ -z "${ref}" ]; then
    echo -e "${RED}ERROR: elicitation infrastructure is not installed.${NC}" >&2
    echo "" >&2
    echo "The Gateway agentgateway-proxy has no EnterpriseAgentgatewayParameters" >&2
    echo "ref, so the proxy doesn't know the STS endpoint and will return" >&2
    echo "\"token exchange required but not configured\" instead of a consent URL." >&2
    echo "" >&2
    echo "Run the one-time setup first:" >&2
    echo "  ./10-install-elicitation.sh" >&2
    exit 1
  fi

  # Warn (don't fail) if the STS runs >1 replica. The proxy will still hand
  # back a consent URL, but the elicitation is stored in an in-memory per-pod
  # DB — so the UI, load-balanced to another replica, shows NO pending
  # authorizations. This is the most confusing way for the demo to "half work".
  local replicas
  replicas=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    get deploy enterprise-agentgateway -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
  if [ "${replicas:-1}" -gt 1 ] 2>/dev/null; then
    echo -e "${YELLOW}WARNING: enterprise-agentgateway has ${replicas} replicas.${NC}" >&2
    echo -e "${YELLOW}  The STS DB is in-memory per-pod, so the pending elicitation may land${NC}" >&2
    echo -e "${YELLOW}  on a different pod than the UI reads — the UI will show nothing to${NC}" >&2
    echo -e "${YELLOW}  authorize. Re-run ./10-install-elicitation.sh (pins replicaCount=1).${NC}" >&2
    echo "" >&2
  fi
}

cleanup() {
  delete_and_wait "${POLICY}" || true
  delete_and_wait "${ROUTE}"  || true
  delete_and_wait "${BACKEND}" || true
  delete_and_wait "${POLICY_JWT}" || true
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    delete secret "${SECRET_NAME}" --ignore-not-found >/dev/null 2>&1 || true
}
trap 'cleanup; _cleanup_portforwards' EXIT

print_elicitation_overview() {
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  Why URL-mode elicitation${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo "  Agents need to call SaaS APIs (GitHub, Google, Salesforce) on"
  echo "  behalf of users. We don't want the MCP server holding shared"
  echo "  credentials, and we don't want users pasting personal tokens"
  echo -e "  into agent config. ${YELLOW}URL-mode elicitation${NC} is the third path:"
  echo "  agentgateway returns a 500 with a one-time consent URL, the"
  echo "  user authorizes in their browser, the STS stores the token,"
  echo "  and the MCP server never sees the credential."
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  Flow${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  cat <<'EOF'

   ① Client → agentgateway: tools/call (JWT)
   ② STS lookup for (user, github-mcp-backend) → no token
   ③ agentgateway → client: HTTP 500 { "url": "<elicitation>", … }
   ④ User opens URL → Solo UI → GitHub OAuth consent
   ⑤ GitHub callback → STS persists access_token
   ⑥ Client retries → agentgateway injects token → GitHub MCP server
   ⑦ MCP server proxies to GitHub API → response

EOF
}

demo_header "Pillar 5 · Security — URL-mode OAuth elicitation (GitHub MCP)"

print_elicitation_overview
prompt_continue "Press Enter to start."

# Pre-flight: env vars must be set.
if [ -z "${GITHUB_CLIENT_ID:-}" ] || [ -z "${GITHUB_CLIENT_SECRET:-}" ]; then
  echo -e "${RED}ERROR: GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET must be set.${NC}" >&2
  echo "" >&2
  echo "Register a GitHub App, then export:" >&2
  echo "  export GITHUB_CLIENT_ID=<from GitHub App page>" >&2
  echo "  export GITHUB_CLIENT_SECRET=<from GitHub App page>" >&2
  echo "" >&2
  echo "App's Redirect URL must be: ${REDIRECT_URI}" >&2
  exit 1
fi

# Fail early with a clear pointer if the one-time infra isn't installed.
require_elicitation_infra

demo_step "① Create the elicitation OAuth secret (GitHub client_id + secret)"
echo "  Secret name: ${SECRET_NAME}"
echo "  redirect_uri: ${REDIRECT_URI}"
echo "  scopes: read:user repo"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  create secret generic "${SECRET_NAME}" \
    --from-literal=type=oauth \
    --from-literal=title="GitHub" \
    --from-literal="instructions=## Authorize GitHub Access\n\nThe agent needs access to your GitHub account to list your repos.\n\nClick **Authorize** to be redirected to GitHub." \
    --from-literal=client_id="${GITHUB_CLIENT_ID}" \
    --from-literal=client_secret="${GITHUB_CLIENT_SECRET}" \
    --from-literal=app_id=github \
    --from-literal=authorize_url=https://github.com/login/oauth/authorize \
    --from-literal=access_token_url=https://github.com/login/oauth/access_token \
    --from-literal=scopes="read:user repo" \
    --from-literal=redirect_uri="${REDIRECT_URI}" \
    --dry-run=client -o yaml \
  | kubectl --context "${CLUSTER_CONTEXT}" apply -f -
echo "  (Per-backend override of the default 10-install-elicitation.sh secret —"
echo "   demonstrates a distinct OAuth app per backend.)"

demo_step "② Apply JWT auth + AgentgatewayBackend + HTTPRoute + EnterpriseAgentgatewayPolicy"
echo "  policy-jwt authenticates bob's token at the gateway so the STS can"
echo "  key the elicitation by his identity. The other three wire up the"
echo "  GitHub MCP backend and its token-exchange/elicitation policy."
show_file "${POLICY_JWT}"
show_file "${BACKEND}"
show_file "${ROUTE}"
show_file "${POLICY}"
prompt_continue
apply_and_wait "${POLICY_JWT}"
apply_and_wait "${BACKEND}"
apply_and_wait "${ROUTE}"
apply_and_wait "${POLICY}"

ensure_gateway_portforward
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")
ACCEPT="application/json, text/event-stream"
TMP=$(mktemp -d)
trap 'cleanup; _cleanup_portforwards; rm -rf "${TMP}"' EXIT

demo_step "③ MCP initialize handshake against /mcp-github — expect HTTP 500 with elicitation URL"
echo "  First call to a token-exchange-protected backend with no stored"
echo "  credential → agentgateway short-circuits the request."
echo ""
status=$(curl -sS --max-time 15 -D "${TMP}/init-h" -o "${TMP}/init-b" -w "%{http_code}" \
  -X POST "${GATEWAY_URL}/mcp-github" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: ${ACCEPT}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{
        "protocolVersion":"2024-11-05",
        "capabilities":{},
        "clientInfo":{"name":"demo-curl","version":"1.0"}}}')
echo -e "${CYAN}# HTTP ${status}${NC}"
if [ "${status}" = "500" ]; then
  # The elicitation URL comes back inside the JSON-RPC error message as a
  # Rust debug string:  ...info: TokenExchangeInfo { url: Some("<URL>"), ... }
  # (NOT a top-level {"url": "..."} field — that's the older/doc shape).
  # Match the Some("...") form first; the \\* tolerates the JSON-escaped
  # \" around the URL. Fall back to the documented {"url":...} shape.
  ELICIT_URL=$(grep -oE 'url: Some\(\\*"[^"\\]+' "${TMP}/init-b" | head -1 \
    | sed -E 's/.*Some\(\\*"//')
  if [ -z "${ELICIT_URL:-}" ]; then
    payload=$(mcp_first_json "${TMP}/init-b")
    if command -v jq >/dev/null 2>&1 && [ -n "${payload}" ]; then
      ELICIT_URL=$(printf '%s' "${payload}" | jq -r '.url // empty' 2>/dev/null)
    fi
  fi
  if [ -z "${ELICIT_URL:-}" ]; then
    ELICIT_URL=$(grep -oE '"url":"[^"]+"' "${TMP}/init-b" | head -1 \
      | sed 's/"url":"//;s/"$//;s#\\/#/#g')
  fi
  if [ -z "${ELICIT_URL:-}" ]; then
    echo -e "${RED}# Got HTTP 500 but couldn't find an elicitation URL in the body:${NC}"
    head -c 400 "${TMP}/init-b"; echo
    echo -e "${YELLOW}# If the body says \"token exchange required but not configured\","
    echo -e "# the elicitation infra isn't wired — run ./10-install-elicitation.sh${NC}"
  fi
  echo -e "${GREEN}# elicitation URL:${NC}"
  echo "    ${ELICIT_URL}"
  echo ""
  echo -e "${RED}❗ FIRST: make sure your GitHub App's Authorization callback URL is set to:${NC}"
  echo -e "     ${RED}${REDIRECT_URI}${NC}"
  echo -e "${RED}   The LoadBalancer address changes on every reinstall, so if you rebuilt${NC}"
  echo -e "${RED}   the cluster this likely differs from what's registered. If it doesn't${NC}"
  echo -e "${RED}   match, GitHub rejects step c with a redirect_uri mismatch.${NC}"
  echo "   (GitHub App settings → General → Authorization callback URL)"
  echo ""
  ensure_ui_portforward
  echo -e "${GREEN}# Solo Enterprise UI is port-forwarded at ${SOLO_UI_URL}${NC}"
  echo -e "${GREEN}#   (this script started it and tears it down on exit)${NC}"
  echo ""
  echo -e "${YELLOW}Then open this URL in a browser. You will:${NC}"
  echo -e "  ${YELLOW}a.${NC} Land on the Solo Enterprise UI and be asked to log in:"
  echo -e "        user: ${BOLD}${DEMO_USER_BOB}${NC}   password: ${BOLD}${DEMO_USER_BOB_PASSWORD}${NC}"
  echo -e "        (via ${KEYCLOAK_EXTERNAL_URL:-your Keycloak})"
  echo -e "        ${CYAN}It must be this user — the STS keys the stored token by${NC}"
  echo -e "        ${CYAN}(userId, backend), so anyone else sees no pending elicitation.${NC}"
  echo -e "  ${YELLOW}b.${NC} Land on the elicitation page → click Authorize → bounce to GitHub"
  echo -e "  ${YELLOW}c.${NC} Approve the OAuth scope on GitHub"
  echo -e "  ${YELLOW}d.${NC} Bounce back to the UI; the STS captures the access_token"
elif [ "${status}" = "000" ]; then
  echo -e "${RED}Could not reach the gateway at ${GATEWAY_URL}.${NC}"
  echo -e "${YELLOW}  GATEWAY_URL is set in your environment, so the script did NOT"
  echo -e "  port-forward. The agentgateway-proxy LB listens on :8080 only."
  echo -e "  Fix with either:"
  echo -e "    export GATEWAY_URL=http://<lb-external-ip>:8080"
  echo -e "    # or, to use a port-forward to localhost:8080 instead:"
  echo -e "    unset GATEWAY_URL${NC}"
  exit 1
else
  echo -e "${RED}Expected 500 + elicitation URL, got HTTP ${status}.${NC}"
  echo -e "Body:"
  [ -s "${TMP}/init-b" ] && head -c 500 "${TMP}/init-b"; echo
fi
prompt_continue "Press Enter once you've completed the OAuth consent in the browser"

demo_step "④ Retry MCP initialize — STS now has a GitHub token; expect HTTP 200"
status=$(curl -sS --max-time 15 -D "${TMP}/init2-h" -o "${TMP}/init2-b" -w "%{http_code}" \
  -X POST "${GATEWAY_URL}/mcp-github" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: ${ACCEPT}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{
        "protocolVersion":"2024-11-05",
        "capabilities":{},
        "clientInfo":{"name":"demo-curl","version":"1.0"}}}')
echo -e "${CYAN}# HTTP ${status}${NC}"
SESSION=$(awk -v IGNORECASE=1 -F': ' 'tolower($1)=="mcp-session-id" {gsub(/\r/,"",$2); print $2; exit}' "${TMP}/init2-h")
if [ -z "${SESSION}" ]; then
  echo -e "${RED}No Mcp-Session-Id returned. Check ext-auth + STS logs.${NC}"
  head -c 500 "${TMP}/init2-b"; echo
  exit 1
fi
echo -e "${CYAN}# Mcp-Session-Id: ${SESSION}${NC}"

curl -sS -o /dev/null -X POST "${GATEWAY_URL}/mcp-github" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: ${ACCEPT}" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: ${SESSION}" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' || true

demo_step "⑤ tools/list against GitHub MCP server — see the live GitHub tool catalog"
status=$(curl -sS -o "${TMP}/tools-b" -w "%{http_code}" \
  -X POST "${GATEWAY_URL}/mcp-github" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: ${ACCEPT}" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: ${SESSION}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
echo -e "${CYAN}# HTTP ${status}${NC}"
payload=$(mcp_first_json "${TMP}/tools-b")
if command -v jq >/dev/null 2>&1 && [ -n "${payload}" ]; then
  echo "${payload}" | jq -r '.result.tools[].name' 2>/dev/null | head -15
else
  echo "${payload}" | head -c 800
fi

echo ""
echo -e "${GREEN}─────────────────────────────────────────────────────────────────${NC}"
echo -e "${GREEN}  What just happened${NC}"
echo -e "${GREEN}─────────────────────────────────────────────────────────────────${NC}"
echo "  - agentgateway intercepted the first call, returned 500 + URL."
echo "  - User completed GitHub OAuth in a browser — out of band, no"
echo "    credential ever touched the MCP server."
echo "  - STS persisted the access_token keyed by (bob, github-mcp-backend)."
echo "  - Retry succeeded; tools/list now returns the GitHub MCP catalog."
echo "  - Subsequent users get their OWN elicitation flow — tokens are"
echo "    not shared across user identities."
echo ""
prompt_continue "Press Enter to revert (deletes policy, route, backend, secret)"
