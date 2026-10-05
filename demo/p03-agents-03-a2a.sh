#!/bin/bash
# Pillar 3 · Case 3: Agent-to-Agent (A2A) task dispatch.
#
# No policies required — the a2a-agent Deployment + /a2a HTTPRoute are
# installed by 07-install-mcp-agents.sh. The HTTPRoute has a URLRewrite
# filter that strips the /a2a prefix before the request reaches the agent.
# This script POSTs a JSON-RPC tasks/send message and shows the reply.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

trap '_cleanup_portforwards' EXIT

demo_header "Pillar 3 · Multi-Agent & Tool Workflows — A2A"

ensure_gateway_portforward
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")

USER_PROMPT="hello from the demo — echo this back"
BODY=$(jq -n --arg p "${USER_PROMPT}" '{
  jsonrpc: "2.0",
  id: "1",
  method: "tasks/send",
  params: {
    id: "1",
    message: {
      role: "user",
      parts: [{type: "text", text: $p}]
    }
  }
}')

demo_step "1. The outbound JSON-RPC request"
say_prompt "${USER_PROMPT}"
echo "${BODY}" | jq .
prompt_continue

demo_step "2. POST /a2a — extract just the result fields, not the full task history"
echo "  (the agent's response includes the FULL task history, which after a few"
echo "   demo runs has hundreds of entries; we pull only what matters here.)"
OUT=$(mktemp)
code=$(curl -sS -o "${OUT}" -w "%{http_code}" --max-time 15 -X POST \
  "${GATEWAY_URL}/a2a" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${BODY}")
case "${code}" in
  2??) echo -e "  ${GREEN}→ HTTP ${code}${NC}" ;;
  *)   echo -e "  ${RED}→ HTTP ${code}${NC}" ;;
esac
jq '{
  jsonrpc, id,
  state: .result.status.state,
  reply: .result.status.message.parts[0].text,
  history_messages: (.result.history | length)
}' "${OUT}" 2>/dev/null || head -c 400 "${OUT}"
rm -f "${OUT}"

echo ""
echo -e "${GREEN}Expected:${NC} state=completed, reply echoes back our text, history grows by"
echo -e "two messages (the user msg + the agent reply) on every tasks/send."
