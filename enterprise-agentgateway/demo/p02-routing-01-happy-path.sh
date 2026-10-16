#!/bin/bash
# Pillar 2 · Case 1: happy-path chat completion through the gateway.
#
# No policies required — this is the baseline path. The /chat HTTPRoute and
# multi-provider AgentgatewayBackend are installed by 06-install-llm-backends.sh.
# Fetches a JWT (so the request carries an identity) and POSTs a small
# chat-completion request; OpenAI should reply.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

demo_header "Pillar 2 · LLM Routing — Happy Path"

demo_step "1. Fetch a JWT from Keycloak (as ${DEMO_USER_BOB})"
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")
echo -e "${CYAN}# decoded claims:${NC}"
jwt_decode "${TOKEN}" | jq '{iss, sub, preferred_username, exp}'

demo_step "2. POST /chat/v1/chat/completions"
gw_post "/chat/v1/chat/completions" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "x-user-id: ${DEMO_USER_BOB}" \
  -H "Content-Type: application/json" \
  --data '{
    "model": "gpt-4o",
    "messages": [
      {"role": "system", "content": "You are a concise assistant."},
      {"role": "user",   "content": "Say hello from Solo Agentgateway in one sentence."}
    ]
  }'

echo ""
echo -e "${GREEN}Expected: a short assistant response from gpt-4o, model field set to gpt-4o.${NC}"
