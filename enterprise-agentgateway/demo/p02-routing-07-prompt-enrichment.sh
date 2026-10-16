#!/bin/bash
# Pillar 2 · Case 7: prompt enrichment.
#
# Applies `EnterpriseAgentgatewayPolicy.backend.ai.promptEnrichment` with
# a prepended system message instructing the model to respond in pirate
# speak. Fires a plain user question; the response should be visibly
# pirate-themed — proving the system message landed before the app's
# request reached the provider.
#
# If the installed chart version doesn't expose the promptEnrichment
# field, applying the policy will fail with "unknown field
# spec.backend.ai.promptEnrichment". In that case the feature needs a
# newer chart — the rest of this script won't run.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

POLICY="${MANIFESTS_DIR}/policy-promptenrichment.yaml"

cleanup() { delete_and_wait "${POLICY}"; }
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 2 · LLM Routing — Prompt Enrichment (pirate mode)"

ensure_gateway_portforward
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")

USER_PROMPT="Describe a sunset in one sentence."

# Compact one-shot helper: POST + extract just {model, content}.
# We do NOT pipe gw_post into jq — gw_post emits a colored "# HTTP 200"
# preamble before the JSON, which jq can't parse. Use a focused curl
# that returns just the body so jq can chew it.
chat() {
  say_prompt "${USER_PROMPT}"
  curl -sS --max-time 15 -X POST \
    "${GATEWAY_URL}/chat/v1/chat/completions" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "x-user-id: ${DEMO_USER_BOB}" \
    -H "Content-Type: application/json" \
    --data "$(jq -n --arg p "${USER_PROMPT}" \
      '{model:"gpt-4o",messages:[{role:"user",content:$p}]}')" \
    | jq '{model, content: .choices[0].message.content}'
}

demo_step "1. Baseline response (no enrichment applied)"
chat

demo_step "2. Show the prompt-enrichment policy"
show_file "${POLICY}"
prompt_continue

demo_step "3. Apply the policy"
apply_and_wait "${POLICY}"
# Give the controller a beat to push the new policy to the proxy.
sleep 2

demo_step "4. Same request — same user prompt, but the policy now prepends"
echo -e "${CYAN}prepended system →${NC} You are a pirate. Always respond in pirate speak..."
chat

echo ""
echo -e "${GREEN}The enriched response should be in pirate speak — the app's user message was${NC}"
echo -e "${GREEN}unchanged, but a platform-owned system message shaped the model's response.${NC}"
echo -e "${YELLOW}Policy APPLIED. Press Enter to revert.${NC}"
prompt_continue "Press Enter to tear down and exit"
