#!/bin/bash
# Pillar 9 · Case 1: routing across two self-hosted vLLM fleets, with policy
# attached per BACKEND rather than per route.
#
# Built for a customer running an OSS gateway in front of two self-hosted vLLM
# servers. The three things shown, in order:
#
#   1. One endpoint, two fleets. The client URL and body never change; a single
#      header moves the request to the other fleet.
#   2. Policy that travels with the fleet. Each AgentgatewayBackend has its own
#      EnterpriseAgentgatewayPolicy attached, injecting a different system prompt.
#      The mock servers echo the system prompt they receive, so the per-backend
#      policy is visible in the response rather than merely asserted.
#   3. Adding a fleet does not mean editing shared route config.
#
# The backends are OpenAI-compatible mocks, not real vLLM — see the header of
# manifests/vllm-mock-deployment.yaml for why, and say so on a call. Every line of
# gateway config here is what a real vLLM target needs.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

FLEET_POLICY="${MANIFESTS_DIR}/policy-vllm-per-backend.yaml"
ROUTE="${MANIFESTS_DIR}/httproute-vllm.yaml"
BACKENDS="${MANIFESTS_DIR}/agentgatewaybackend-vllm.yaml"

cleanup() { delete_and_wait "${FLEET_POLICY}"; }
trap 'cleanup; _cleanup_portforwards' EXIT

# The gateway-wide jwt-auth policy is applied only by the p05 security demos, but
# if one was interrupted it can be left behind — in which case every request here
# needs a bearer token. Send one when it is present so this step works either way.
# AUTH_ARGS is seeded with a harmless marker header so it is NEVER empty. Two
# reasons, both of which bit this script: under `set -u`, bash 3.2 (what macOS
# ships) treats "${arr[@]}" on an empty array as an unbound variable and aborts;
# and the +-guarded workaround, ${arr[@]+"${arr[@]}"}, needs an unquoted outer
# expansion that shellcheck flags as SC2068. A non-empty array sidesteps both.
AUTH_ARGS=(-H "x-demo-pillar: p09")
if kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
     get enterpriseagentgatewaypolicy jwt-auth >/dev/null 2>&1; then
  TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")
  AUTH_ARGS+=(-H "Authorization: Bearer ${TOKEN}")
fi

BODY='{"model":"gemma-4","messages":[{"role":"user","content":"Who are you, and what data may I send you?"}]}'

# Print just the fields that carry the story: which fleet answered, and what
# system prompt it saw. Full bodies bury that in noise on a projector.
report() {
  local label="$1"; shift
  echo -e "${CYAN}${label}${NC}"
  gw_post "/vllm/v1/chat/completions" \
    -H 'content-type: application/json' "${AUTH_ARGS[@]}" "$@" -d "${BODY}" \
    | python3 -c '
import json, sys
raw = sys.stdin.read()
start = raw.find("{")
if start < 0:
    print("  (no JSON body)"); sys.exit()
try:
    d = json.loads(raw[start:])
except Exception:
    print("  (unparseable body)"); sys.exit()
print("  served by      :", d.get("model"))
print("  usage (tokens) :", (d.get("usage") or {}).get("total_tokens"))
msg = ((d.get("choices") or [{}])[0].get("message") or {}).get("content", "")
print("  response       :", msg[:200])
'
}

demo_header "Pillar 9 · Self-Hosted Models — Routing across two vLLM fleets"

demo_step "1. The two self-hosted backends"
echo "Pointing agentgateway at a self-hosted vLLM server is host + port + path."
echo "Swapping these mocks for real vLLM servers changes the host and nothing else."
show_file "${BACKENDS}"
prompt_continue

demo_step "2. One route, two fleets — the header is the only difference"
show_file "${ROUTE}"
prompt_continue

demo_step "3. Default request — no routing header"
say_prompt "Who are you, and what data may I send you?"
report "→ POST /vllm  (no x-model header)"

demo_step "4. Same URL, same body, one header added"
report "→ POST /vllm  -H 'x-model: llama-30'" -H 'x-model: llama-30'
echo ""
echo -e "${YELLOW}The client never changed its endpoint. The platform moved the traffic.${NC}"
prompt_continue

demo_step "5. Attach a DIFFERENT policy to each backend"
echo "targetRefs points at an AgentgatewayBackend, so the policy travels with the"
echo "fleet. Route both through one endpoint and each keeps its own rules."
show_file "${FLEET_POLICY}"
prompt_continue
apply_and_wait "${FLEET_POLICY}"

demo_step "6. Re-send both requests — each fleet now enforces its own policy"
report "→ gemma-4 fleet" 
report "→ llama-30 fleet" -H 'x-model: llama-30'
echo ""
echo -e "${GREEN}Each backend injected its own system prompt. Same route, same client,"
echo -e "different governance per fleet.${NC}"

prompt_continue "Press Enter to remove the per-backend policies and finish"
