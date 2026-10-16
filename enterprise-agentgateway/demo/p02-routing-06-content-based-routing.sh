#!/bin/bash
# Pillar 2 · Case 6: content-based routing.
#
# Applies a demo-only HTTPRoute at /chat-content with two rules:
#   - x-model: mock   → mock-llm  AgentgatewayBackend
#   - (no header)     → openai    AgentgatewayBackend (fallback)
#
# Fires one request with each header value and shows the different
# `model` fields in the responses to prove the header drove the routing.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

ROUTE="${MANIFESTS_DIR}/httproute-chat-content-based.yaml"

cleanup() { delete_and_wait "${ROUTE}"; }
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 2 · LLM Routing — Content-Based Routing (by x-model header)"

demo_step "1. Show the HTTPRoute"
show_file "${ROUTE}"
prompt_continue

demo_step "2. Apply the route"
apply_and_wait "${ROUTE}"

ensure_gateway_portforward
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")

demo_step "3. Request WITHOUT x-model — expect upstream model = openai (gpt-4o)"
gw_post "/chat-content/v1/chat/completions" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "x-user-id: ${DEMO_USER_BOB}" \
  -H "Content-Type: application/json" \
  --data '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}' \
  | head -20

demo_step "4. Request WITH x-model: mock — expect mock-llm-1 as the model"
gw_post "/chat-content/v1/chat/completions" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "x-user-id: ${DEMO_USER_BOB}" \
  -H "x-model: mock" \
  -H "Content-Type: application/json" \
  --data '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}' \
  | head -20

echo ""
echo -e "${GREEN}The model field flipped from gpt-* to mock-llm-1 just by setting x-model.${NC}"
echo -e "${YELLOW}Route is currently APPLIED. Press Enter to tear down.${NC}"
prompt_continue "Press Enter to tear down and exit"
