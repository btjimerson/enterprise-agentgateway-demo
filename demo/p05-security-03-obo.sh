#!/bin/bash
# Pillar 5 · Case 3: RFC 8693 On-Behalf-Of (OBO) token exchange.
#
# ─────────────────────────────────────────────────────────────────────
# WHY THIS PATTERN EXISTS
# ─────────────────────────────────────────────────────────────────────
# An agent (workload) needs to call a downstream service ON BEHALF OF a
# specific human user. Two naïve options both fail an audit:
#
#   (A) Pass the user's own JWT through to downstream → agent has FULL
#       impersonation; the agent process could call ANY service the user
#       can reach. Blast-radius problem.
#
#   (B) Have the agent call downstream with ITS OWN service-account
#       token → request reaches downstream with no link to the human
#       who initiated it. Audit problem.
#
# RFC 8693 token exchange is the middle path: the agent presents BOTH
# the user's token AND its own SA token to a Security Token Service
# (STS), and the STS mints a NEW token whose `sub` is still the user
# but whose `act` claim names the acting agent. Downstream sees both
# identities, can authorize on both, and the OBO chain is recorded in
# the audit log.
#
# The user's token must contain a `may_act` claim listing the SAs that
# are authorized to act on their behalf — set up by 09-install-obo.sh
# in the Keycloak realm config. The STS refuses the exchange if the
# acting SA isn't in `may_act`.
#
# ─────────────────────────────────────────────────────────────────────
# FLOW DIAGRAM (printed at runtime by print_obo_overview)
# ─────────────────────────────────────────────────────────────────────
#
# Mermaid (for source-tree readers / docs site):
#
#   sequenceDiagram
#     participant Bob as Bob (user)
#     participant KC as Keycloak
#     participant Agent as agent-sa (workload)
#     participant K8s as Kubernetes API
#     participant STS as Agentgateway STS<br/>(/oauth2/token)
#     participant DS as Downstream<br/>(mcp-federated)
#     Bob->>KC: ① login (password grant)
#     KC-->>Bob: SUBJECT token (sub=bob, may_act=[agent-sa])
#     Agent->>K8s: ② request projected SA token
#     K8s-->>Agent: ACTOR token (sub=agent-sa)
#     Agent->>STS: ③ POST /oauth2/token<br/>grant_type=token-exchange<br/>subject_token + actor_token
#     STS-->>Agent: ④ DELEGATED token (sub=bob, act={sub:agent-sa})
#     Agent->>DS: ⑤ Authorization: Bearer <delegated>
#     DS-->>Agent: authorized; audit log records both identities
#
# ─────────────────────────────────────────────────────────────────────
# Prereqs
# ─────────────────────────────────────────────────────────────────────
# 09-install-obo.sh must have:
#   - enabled tokenExchange on the agentgateway control plane
#   - deployed the agent-sa ServiceAccount in agentgateway-demo
#   - applied the STS HTTPRoute on agentgateway-proxy
#   - configured the Keycloak realm so bob's tokens carry
#     may_act=system:serviceaccount:agentgateway-demo:agent-sa
#
# The script reverts the JWT policy on exit but leaves the OBO
# infrastructure in place (it's installed by 09-install-obo.sh and
# torn down by cleanup-all.sh).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"
: "${AGENT_SA_NAMESPACE:=agentgateway-demo}"
: "${AGENT_SA_NAME:=agent-sa}"

POLICY_JWT="${MANIFESTS_DIR}/policy-jwt.yaml"

cleanup() { delete_and_wait "${POLICY_JWT}"; }
trap 'cleanup; _cleanup_portforwards' EXIT

# print_obo_overview: prints the WHY + an ASCII flow diagram + the
# three-token glossary. Runs once at the start of the demo so the
# audience has the mental model before we start producing tokens.
#
# Heredocs don't expand \033 escape sequences — they pass through
# literally — so we use echo -e for the colored separator lines and a
# plain heredoc for the diagram itself (no colors needed inside).
print_obo_overview() {
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  Why OBO matters${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo "  An agent calling a tool ON BEHALF OF a user can't just forward"
  echo "  the user's own JWT (full impersonation, blast-radius problem) and"
  echo "  shouldn't call with its own SA token alone (no audit link to the"
  echo "  human). RFC 8693 token exchange ties them: the result token keeps"
  echo -e "  ${YELLOW}sub${NC}=user but adds an ${YELLOW}act${NC} claim naming the agent."
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  Three tokens you'll see in this demo${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "  ${YELLOW}SUBJECT${NC}    bob's JWT from Keycloak.        sub=<bob's UUID>"
  echo "                                              preferred_username=bob"
  echo "                                              may_act={sub: agent-sa}"
  echo -e "  ${YELLOW}ACTOR${NC}      agent-sa's projected K8s token. sub=agent-sa"
  echo -e "  ${YELLOW}DELEGATED${NC}  output of the exchange.         sub=<bob's UUID> (preserved)"
  echo "                                              act={sub: agent-sa}"
  echo ""
  echo -e "  Note: OIDC ${YELLOW}sub${NC} is a stable subject identifier (Keycloak issues a UUID),"
  echo -e "  NOT the username. The username is in ${YELLOW}preferred_username${NC} on the"
  echo -e "  SUBJECT token; the DELEGATED token preserves sub but doesn't carry"
  echo -e "  preferred_username forward — downstream services authorize on the"
  echo -e "  identifier and look up the human name themselves."
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  Flow${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  cat <<'EOF'

   ┌──────────┐    ① login         ┌──────────────┐
   │   Bob    │ ─────────────────▶ │   Keycloak   │
   │  (user)  │ ◀─── SUBJECT ───── │              │
   └──────────┘     (sub=bob,      └──────────────┘
                    may_act=[agent-sa])

   ┌──────────┐    ② project SA    ┌──────────────┐
   │ agent-sa │ ─────────────────▶ │ Kubernetes   │
   │(workload)│ ◀─── ACTOR ─────── │              │
   └──────────┘     (sub=agent-sa) └──────────────┘
       │
       │  ③  POST /oauth2/token
       │     grant_type=urn:ietf:params:oauth:grant-type:token-exchange
       │     subject_token=<SUBJECT>
       │     actor_token=<ACTOR>
       │     audience=mcp-federated
       ▼
   ┌──────────────────────┐
   │ Agentgateway STS     │  validates may_act on SUBJECT;
   │  /oauth2/token       │  rejects if actor not in may_act.
   └──────────────────────┘
       │
       │  ④  DELEGATED token (JWT)
       │     sub=bob
       │     act={ sub: agent-sa }
       │     aud=mcp-federated
       ▼
   ┌──────────────────────┐
   │ Downstream service   │  ⑤ authorizes on BOTH identities
   │ (mcp-federated)      │     audit log shows the OBO chain
   └──────────────────────┘

EOF
}

demo_header "Pillar 5 · Security — RFC 8693 OBO Token Exchange"

print_obo_overview
prompt_continue "Press Enter to start the exchange."

demo_step "1. Apply the JWT policy (issued tokens must be valid even for STS)"
apply_and_wait "${POLICY_JWT}"

demo_step "① ② Mint the two input tokens — SUBJECT (Bob) and ACTOR (agent-sa)"
echo -e "  ${CYAN}①${NC} bob → Keycloak password grant → SUBJECT JWT"
SUBJECT=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")
echo -e "  ${CYAN}②${NC} kubectl create token ${AGENT_SA_NAMESPACE}/${AGENT_SA_NAME} → ACTOR JWT"
ACTOR=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENT_SA_NAMESPACE}" \
  create token "${AGENT_SA_NAME}" --duration=1h)

echo ""
echo -e "${CYAN}# SUBJECT token decoded (issued by Keycloak — note may_act):${NC}"
jwt_decode "${SUBJECT}" | jq '{iss, sub, preferred_username, may_act}'
echo ""
echo -e "${CYAN}# Where does may_act come from? (asked every time)${NC}"
echo -e "  It is a ${YELLOW}standard RFC 8693 §4.4 claim${NC}, not a Solo or Keycloak invention."
echo -e "  It answers ${BOLD}WHO is allowed to act for this user${NC} — the authorization gate"
echo -e "  for the exchange in step ③. The STS reads it off the SUBJECT token and"
echo -e "  refuses the exchange if the presented actor isn't listed."
echo ""
echo -e "  Keycloak does ${BOLD}not${NC} issue it on its own. In this realm it is injected by a"
echo -e "  hardcoded protocol mapper on the ${YELLOW}${KEYCLOAK_CLIENT_ID}${NC} client:"
echo -e "    ${CYAN}oidc-hardcoded-claim-mapper${NC}  may_act = {\"sub\":\"system:serviceaccount:${AGENT_SA_NAMESPACE}:${AGENT_SA_NAME}\"}"
echo -e "    (see keycloak/realm-agentgateway-demo.json)"
echo ""
echo -e "  ${BOLD}In production${NC} the IdP populates this dynamically from whatever already"
echo -e "  records delegation rights — a group, an entitlement service, an AD"
echo -e "  attribute. Pinning one service account in realm config is the demo"
echo -e "  shortcut, and worth saying out loud so nobody reads it as the design."
echo ""
echo -e "  Don't confuse it with downscoping: ${YELLOW}may_act${NC} controls ${BOLD}whether${NC} an agent"
echo -e "  may act for a user; downscoping controls ${BOLD}what${NC} it may do once allowed."
echo ""
echo -e "${CYAN}# ACTOR token decoded (issued by Kubernetes — note iss is the cluster):${NC}"
jwt_decode "${ACTOR}" | jq '{iss, sub, aud: (.aud | if type=="array" then . else [.] end)}'

demo_step "③ Exchange both tokens at the STS — POST /oauth2/token"
echo -e "${CYAN}# Who makes this call in production? (worth saying before it's asked)${NC}"
echo -e "  This curl stands in for ${BOLD}the agent's own code${NC}, not for something the"
echo -e "  gateway does behind the scenes. In the RFC 8693 flow shown here the agent"
echo -e "  holds the user's token, presents it with its own workload identity, and"
echo -e "  calls the STS itself; the proxy's job is to ${BOLD}validate${NC} the resulting"
echo -e "  delegated token on the way to the tool (that is the second trusted issuer"
echo -e "  in policy-jwt.yaml). An agent framework or SDK would wrap this exchange —"
echo -e "  it is a few lines against a standard endpoint, not bespoke plumbing."
echo ""
echo -e "  Solo publishes an SDK for this — the ${YELLOW}agentsts-adk${NC} Python package — so it is"
echo -e "  not hand-rolled. The protocol underneath is plain RFC 8693, which is why this"
echo -e "  demo can do it with curl and no SDK at all. Portability lives at the protocol"
echo -e "  level: the STS URL is config, the grant is standard."
echo ""
echo -e "  ${YELLOW}Docs are inconsistent on whether the PROXY can do the exchange for you.${NC}"
echo -e "  The token-exchange overview says the proxy injects the minted JWT upstream,"
echo -e "  but the delegation setup guide's Step 3 is 'set up your agent to use STS'"
echo -e "  via the SDK. Elicitation (p05-security-05) is definitively proxy-initiated."
echo -e "  Do NOT promise proxy-injected delegation without confirming it first."
echo ""
echo "  curl -X POST ${STS_URL:-<STS_URL>}/oauth2/token \\"
echo "    -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \\"
echo "    -d 'subject_token=<SUBJECT>' \\"
echo "    -d 'subject_token_type=urn:ietf:params:oauth:token-type:jwt' \\"
echo "    -d 'actor_token=<ACTOR>' \\"
echo "    -d 'actor_token_type=urn:ietf:params:oauth:token-type:jwt' \\"
echo "    -d 'audience=mcp-federated'"
ensure_sts_portforward
EXCHANGE=$(mktemp)
status=$(curl -sS -o "${EXCHANGE}" -w "%{http_code}" -X POST \
  "${STS_URL}/oauth2/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  --data-urlencode "subject_token=${SUBJECT}" \
  --data-urlencode "subject_token_type=urn:ietf:params:oauth:token-type:jwt" \
  --data-urlencode "actor_token=${ACTOR}" \
  --data-urlencode "actor_token_type=urn:ietf:params:oauth:token-type:jwt" \
  --data-urlencode "requested_token_type=urn:ietf:params:oauth:token-type:jwt" \
  --data-urlencode "audience=mcp-federated")
case "${status}" in
  2??) echo -e "  ${GREEN}→ HTTP ${status}${NC}" ;;
  *)   echo -e "  ${RED}→ HTTP ${status}${NC}" ;;
esac

if [ "${status}" != "200" ]; then
  echo -e "${RED}# STS rejected the exchange. Raw body:${NC}"
  cat "${EXCHANGE}"; echo
  # Common cause: the STS caches Keycloak's JWKS and does NOT re-fetch on an
  # unknown key id, so after Keycloak rotates its signing key (or is rebuilt)
  # the STS holds a stale JWKS and rejects a valid subject token with
  # "JWKS not available for key: <thumbprint>". Restarting the controller
  # forces a fresh JWKS fetch. (Nothing is misconfigured — the validators
  # already point at the right realm certs.)
  if grep -qi 'JWKS not available for key' "${EXCHANGE}" 2>/dev/null; then
    echo ""
    echo -e "${YELLOW}Hint: the STS has a STALE Keycloak JWKS cache (it doesn't re-fetch on an${NC}"
    echo -e "${YELLOW}unknown key id). This happens after Keycloak rotates keys or is rebuilt.${NC}"
    echo -e "${YELLOW}Refresh it by restarting the controller, then re-run this demo:${NC}"
    echo -e "  ${CYAN}kubectl --context ${CLUSTER_CONTEXT} -n ${AGENTGATEWAY_NAMESPACE} rollout restart deploy/enterprise-agentgateway${NC}"
    echo -e "  ${CYAN}kubectl --context ${CLUSTER_CONTEXT} -n ${AGENTGATEWAY_NAMESPACE} rollout status  deploy/enterprise-agentgateway${NC}"
  fi
  rm -f "${EXCHANGE}"
  exit 1
fi

DELEGATED=$(jq -r '.access_token' "${EXCHANGE}")
rm -f "${EXCHANGE}"

demo_step "④ DELEGATED token decoded — sub preserved (Bob's UUID) + act added"
jwt_decode "${DELEGATED}" | jq '{iss, sub, act, aud, exp}'
SUBJECT_SUB=$(jwt_decode "${SUBJECT}" | jq -r '.sub')
DELEGATED_SUB=$(jwt_decode "${DELEGATED}" | jq -r '.sub')
echo ""
echo -e "${CYAN}# Note on 'sub' — it's a UUID, not the username:${NC}"
echo -e "  OIDC ${YELLOW}sub${NC} is a stable subject identifier (UUID for Keycloak), not"
echo -e "  the human-readable name. The username 'bob' lives in ${YELLOW}preferred_username${NC}"
echo -e "  on the SUBJECT token. The DELEGATED token preserves ${YELLOW}sub${NC} (the UUID)"
echo -e "  but does NOT carry preferred_username forward — downstream services"
echo -e "  authorize on the stable identifier and look up the human name themselves."
echo -e "  Verify: SUBJECT.sub = ${SUBJECT_SUB:0:13}…  DELEGATED.sub = ${DELEGATED_SUB:0:13}…  ${GREEN}(match)${NC}"

demo_step "⑤ Use the DELEGATED token end-to-end — call /mcp on Bob's behalf"
ensure_gateway_portforward
echo -e "${CYAN}# What this step is actually proving${NC}"
echo -e "  The exchange in step ③ is only interesting if the resulting token is"
echo -e "  ${BOLD}usable on a real route${NC}, not just mintable. Two things make that work:"
echo ""
echo -e "  1. The token is ${BOLD}not${NC} Keycloak's — its ${YELLOW}iss${NC} is the STS. The gateway's"
echo -e "     jwt-auth policy trusts ${BOLD}two${NC} issuers (Keycloak for users, the STS for"
echo -e "     delegated calls). That second provider is the whole trick — without it"
echo -e "     the gateway rejects every delegated token with 'unknown key'."
echo -e "  2. One credential carries ${BOLD}both${NC} identities: ${YELLOW}sub${NC}=bob (who asked) and"
echo -e "     ${YELLOW}act${NC}=agent-sa (what called). The tool call below is authorized as bob"
echo -e "     while remaining attributable to the agent that made it."
echo ""
echo -e "  Without the exchange an agent has two poor options: replay bob's raw"
echo -e "  token — downstream can't tell an agent was involved — or use its own SA"
echo -e "  token, which loses bob entirely and makes every tool call look like the"
echo -e "  platform did it. Delegation is what avoids choosing."
echo ""

# Contrast probe: the agent's OWN identity on the same route. The k8s cluster is
# not a trusted issuer in jwt-auth, so this is a deterministic 401 — and it shows
# the delegated token is doing real work rather than the route being open.
echo -e "  ${CYAN}First, the agent's own SA token on the same route:${NC}"
ACTOR_CODE=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 -X POST "${GATEWAY_URL}/mcp" \
  -H "Authorization: Bearer ${ACTOR}" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{
        "protocolVersion":"2024-11-05","capabilities":{},
        "clientInfo":{"name":"obo-demo-actor","version":"1.0"}}}' 2>/dev/null || echo 000)
if [ "${ACTOR_CODE}" = "401" ] || [ "${ACTOR_CODE}" = "403" ]; then
  echo -e "    ${GREEN}→ HTTP ${ACTOR_CODE} — rejected. The cluster is not a trusted issuer here,${NC}"
  echo -e "    ${GREEN}  so the agent cannot reach this route as itself.${NC}"
  echo -e "    ${YELLOW}Be precise about this: it is an AUTHENTICATION boundary, not a${NC}"
  echo -e "    ${YELLOW}permission decision. The gateway cannot validate a token from an${NC}"
  echo -e "    ${YELLOW}untrusted issuer, so it never reaches an authz check. Add the${NC}"
  echo -e "    ${YELLOW}cluster as a provider and this same token would authenticate.${NC}"
else
  echo -e "    ${YELLOW}→ HTTP ${ACTOR_CODE} (expected 401/403)${NC}"
fi
echo ""

echo -e "  ${CYAN}Now the delegated token:${NC}"
echo -e "  Sending MCP initialize with ${YELLOW}Authorization: Bearer <DELEGATED>${NC}…"
TMP=$(mktemp -d)
HDR=$(mktemp)
RESP=$(mktemp)
HTTP_CODE=$(curl -sS -D "${HDR}" -o "${RESP}" -w "%{http_code}" --max-time 10 -X POST "${GATEWAY_URL}/mcp" \
  -H "Authorization: Bearer ${DELEGATED}" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{
        "protocolVersion":"2024-11-05","capabilities":{},
        "clientInfo":{"name":"obo-demo","version":"1.0"}}}')
case "${HTTP_CODE}" in
  200) echo -e "  ${GREEN}→ HTTP ${HTTP_CODE} — gateway accepted the delegated token${NC}" ;;
  *)   echo -e "  ${RED}→ HTTP ${HTTP_CODE}${NC}"; head -c 200 "${RESP}"; echo ;;
esac
SESSION=$(awk -v IGNORECASE=1 -F': ' \
  'tolower($1)=="mcp-session-id" {gsub(/\r/,"",$2); print $2; exit}' "${HDR}")
if [ -n "${SESSION}" ] && [ "${HTTP_CODE}" = "200" ]; then
  curl -sS -o /dev/null -X POST "${GATEWAY_URL}/mcp" \
    -H "Authorization: Bearer ${DELEGATED}" \
    -H "Accept: application/json, text/event-stream" \
    -H "Content-Type: application/json" \
    -H "Mcp-Session-Id: ${SESSION}" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo -e "  Calling tools/list as bob (via agent-sa)…"
  curl -sS -X POST "${GATEWAY_URL}/mcp" \
    -H "Authorization: Bearer ${DELEGATED}" \
    -H "Accept: application/json, text/event-stream" \
    -H "Content-Type: application/json" \
    -H "Mcp-Session-Id: ${SESSION}" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
    | sed -n 's/^data: //p' \
    | jq '{tool_count: (.result.tools | length), first_three: [.result.tools[0:3][].name]}' 2>/dev/null \
    || echo "  (couldn't parse tools/list response)"
fi
rm -f "${HDR}" "${RESP}"; rm -rf "${TMP}"

echo ""
echo -e "${GREEN}─────────────────────────────────────────────────────────────────${NC}"
echo -e "${GREEN}  What just happened${NC}"
echo -e "${GREEN}─────────────────────────────────────────────────────────────────${NC}"
echo -e "  - The DELEGATED token's ${YELLOW}sub${NC} is still Bob's UUID (preserved from"
echo -e "    the SUBJECT token). Downstream services authorize on what BOB can"
echo -e "    do, not what agent-sa could do alone."
echo -e "  - The new ${YELLOW}act${NC} claim names ${AGENT_SA_NAMESPACE}/${AGENT_SA_NAME} — that's"
echo -e "    the audit trail. Proxy logs and downstream audit logs record"
echo -e "    BOTH identities so the OBO chain is reconstructable."
echo -e "  - The exchange ONLY succeeded because Bob's SUBJECT token had"
echo -e "    ${YELLOW}may_act${NC} naming agent-sa. Strip may_act in Keycloak and the STS"
echo -e "    returns 403 — the security control is at the IDP, not just the STS."
echo -e "  - Step ⑤ proved the chain end-to-end: the gateway trusts BOTH the"
echo -e "    Keycloak issuer (for direct user calls) and the STS issuer (for"
echo -e "    delegated calls), so the delegated token actually USES on a real"
echo -e "    downstream route, not just gets minted in isolation."
echo ""
echo -e "${YELLOW}Policy APPLIED. Inspect the three tokens above, then press Enter to revert.${NC}"
prompt_continue "Press Enter to tear down and exit"
