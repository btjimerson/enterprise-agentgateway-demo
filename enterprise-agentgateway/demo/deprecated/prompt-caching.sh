#!/bin/bash
# DEPRECATED — was Pillar 2 · Case 4: prompt caching. Not part of the demo set.
#
# ─────────────────────────────────────────────────────────────────────
# WHY THIS IS DEPRECATED
# ─────────────────────────────────────────────────────────────────────
# The step was a no-op on screen: it applied a policy, fired two identical
# requests, and nothing observable happened — no cache hit, no metric, no
# latency delta. Three independent reasons, all of which had to be fixed
# together for it to demonstrate anything:
#
#   1. The provider can't show it. The demo targets gpt-4o, and OpenAI does
#      not return usage.cached_input_tokens, so cache hits are opaque through
#      the API — there is no signal for the gateway or the UI to surface.
#   2. The prompt is far too short. OpenAI only caches prompts >= 1024 tokens;
#      the system prompt here is ~60.
#   3. The policy's own threshold is never met either. policy-promptcache.yaml
#      sets minTokens: 1024, so cacheSystem never triggers on this prompt even
#      on a provider that caches well.
#
# Making it work meant an Anthropic backend on the /chat route (the existing
# Anthropic wiring is native Messages API on /claude, so not a drop-in), a
# >=1024-token system prompt, and verifying the numbers actually surface. Judged
# not worth it against a step that demonstrated nothing, so the step was cut.
#
# KEPT, NOT DELETED, because the policy shape is still a useful reference and
# the analysis above is worth not re-deriving. Prompt caching remains a real
# feature — this walkthrough just doesn't prove it.
#
# To run it anyway (it still works, it just doesn't SHOW anything):
#   RUN_DEPRECATED_DEMO=1 ./demo/deprecated/prompt-caching.sh
#
# Original notes:
#   Applies policy-promptcache.yaml, which enables provider-native prompt
#   caching on /chat (useful for long system prompts + repeated tool defs).
#     - Anthropic / Bedrock surface cached_input_tokens in usage.
#     - OpenAI's cache_hit telemetry is opaque through the API.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../_common.sh"

if [ "${RUN_DEPRECATED_DEMO:-}" != "1" ]; then
  echo ""
  echo -e "${YELLOW}────────────────────────────────────────────────────────────${NC}"
  echo -e "${YELLOW}  DEPRECATED — this step is not part of the demo set${NC}"
  echo -e "${YELLOW}────────────────────────────────────────────────────────────${NC}"
  echo "  Prompt caching was cut because the step demonstrated nothing:"
  echo "  OpenAI doesn't report cache hits through its API, the demo prompt is"
  echo "  ~60 tokens against a 1024-token provider minimum, and the policy's own"
  echo "  minTokens is 1024 too."
  echo "  file for the full reasoning."
  echo ""
  echo -e "  ${GREEN}Nothing was applied.${NC} To run it anyway:"
  echo "    RUN_DEPRECATED_DEMO=1 $0"
  echo ""
  exit 0
fi

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

POLICY_CACHE="${MANIFESTS_DIR}/policy-promptcache.yaml"

cleanup() { delete_and_wait "${POLICY_CACHE}"; }
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 2 · LLM Routing — Prompt Caching"

demo_step "1. Show the prompt-cache policy"
show_file "${POLICY_CACHE}"
prompt_continue

demo_step "2. Apply the policy"
apply_and_wait "${POLICY_CACHE}"

demo_step "3. Fire two identical /chat requests — second one is a cache candidate"
ensure_gateway_portforward
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")
SYSTEM_PROMPT="You are an assistant that repeats the system context verbatim then answers briefly. The system context is: Solo Enterprise for Agentgateway provides a unified AI control plane with LLM routing, policy-driven governance, MCP + A2A support, and deep observability."
USER_PROMPT="List two benefits of an AI gateway in one short sentence each."
echo -e "${CYAN}system prompt →${NC} ${SYSTEM_PROMPT:0:100}…"
say_prompt "${USER_PROMPT}"
BODY=$(jq -n --arg s "${SYSTEM_PROMPT}" --arg u "${USER_PROMPT}" \
  '{model:"gpt-4o",messages:[{role:"system",content:$s},{role:"user",content:$u}]}')
for i in 1 2; do
  echo ""
  echo -e "${CYAN}# request ${i}:${NC}"
  gw_post "/chat/v1/chat/completions" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "x-user-id: ${DEMO_USER_BOB}" \
    -H "Content-Type: application/json" \
    --data "${BODY}" || true
done

echo ""
echo -e "${GREEN}Prompt-cache policy applied; two identical /chat requests sent.${NC}"
echo ""
echo -e "${CYAN}Token volume shows in the Solo Enterprise UI${NC} (run in a second terminal):"
echo -e "    kubectl --context ${CLUSTER_CONTEXT} -n ${AGENTGATEWAY_NAMESPACE} port-forward svc/solo-enterprise-ui 4000:80"
echo -e "    open http://localhost:4000/age/        # log in as ${DEMO_USER_BOB} / ${DEMO_USER_BOB_PASSWORD}"
echo -e "    → Dashboard → the 'Tokens Used' counter   # shortcut: ../../ui-login.sh"
echo ""
echo -e "${YELLOW}NOTE — a cache HIT is not observable in this demo.${NC} The Solo UI shows"
echo -e "  only a 'Tokens Used' counter (no cache breakdown), and this demo targets"
echo -e "  OpenAI (gpt-4o) — whose cache hits are opaque through its API and only"
echo -e "  engage for prompts >=1024 tokens (this prompt is far shorter). To make a"
echo -e "  cache hit visible: route to an Anthropic/Bedrock backend (surfaces"
echo -e "  usage.cached_input_tokens) with a long (>=1024-token) prompt."
echo ""
echo -e "${YELLOW}Policy APPLIED. Inspect, then press Enter to revert.${NC}"
prompt_continue "Press Enter to tear down and exit"
