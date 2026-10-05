#!/bin/bash
# Pillar 8 · Case 1: per-route model-feature controls — tool-calling off.
#
# Applies policy-tool-disable.yaml, which uses spec.backend.ai.overrides to
# force every request to have `tools: []` and `tool_choice: "none"` before
# it reaches the provider. The client can ship any tool definitions it
# wants — the gateway strips them, and the response comes back as a plain
# assistant message (no tool_calls).
#
# Reverts the policy on exit.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

POLICY="${MANIFESTS_DIR}/policy-tool-disable.yaml"

cleanup() { delete_and_wait "${POLICY}"; }
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 8 · Model Feature Controls — Tool Calling Disabled"

ensure_gateway_portforward
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")

USER_PROMPT="What time is it? Use a tool if you have one."
BODY=$(jq -n --arg p "${USER_PROMPT}" '{
  model: "gpt-4o",
  messages: [{role: "user", content: $p}],
  tools: [{
    type: "function",
    function: {
      name: "get_time",
      description: "gets the current time",
      parameters: {type: "object", properties: {}}
    }
  }],
  tool_choice: "auto"
}')

# fire_chat: send the request, show finish_reason / has_tool_calls /
# tool name (if any) / content preview. Same shape regardless of
# policy state so before/after are visually comparable.
fire_chat() {
  local label="$1"
  echo -e "${CYAN}# ${label}${NC}"
  local out; out=$(mktemp)
  local code
  code=$(curl -sS -o "${out}" -w "%{http_code}" --max-time 15 -X POST \
    "${GATEWAY_URL}/chat/v1/chat/completions" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "x-user-id: ${DEMO_USER_BOB}" \
    -H "Content-Type: application/json" \
    -d "${BODY}")
  case "${code}" in
    2??) echo -e "  ${GREEN}→ HTTP ${code}${NC}" ;;
    *)   echo -e "  ${RED}→ HTTP ${code}${NC}" ;;
  esac
  jq '{
    finish_reason: .choices[0].finish_reason,
    has_tool_calls: (.choices[0].message.tool_calls != null),
    tool_call: (.choices[0].message.tool_calls[0].function.name // null),
    content: (.choices[0].message.content | tostring | .[0:160])
  }' "${out}" 2>/dev/null || head -c 300 "${out}"
  rm -f "${out}"
}

demo_step "1. Show the user prompt + the outbound request body (client asks for tool-calling)"
say_prompt "${USER_PROMPT}"
echo "${BODY}" | jq .
prompt_continue

demo_step "2. BEFORE the policy — fire the request; tool_calls comes back"
echo "  (no policy active — gateway forwards the request unchanged)"
fire_chat "baseline (no policy)"
echo ""
echo -e "  ${YELLOW}Expected:${NC} finish_reason=tool_calls, has_tool_calls=true,"
echo -e "  tool_call=get_time. The model wants to invoke our tool."
echo ""
prompt_continue "Now we'll apply the tool-disable policy."

demo_step "3. Show + apply the tool-disable policy"
show_file "${POLICY}"
apply_and_wait "${POLICY}"

demo_step "4. AFTER the policy — same request, tools stripped before reaching OpenAI"
fire_chat "policy active (tools stripped)"
echo ""
echo -e "  ${YELLOW}Expected:${NC} finish_reason=stop, has_tool_calls=false,"
echo -e "  tool_call=null, content=plain-text answer. The gateway forced"
echo -e "  tools=[] + tool_choice=none on the way out, so the model"
echo -e "  couldn't ask for a tool even if it wanted to."

echo ""
echo -e "${GREEN}─────────────────────────────────────────────────────────────────${NC}"
echo -e "${GREEN}  What just happened${NC}"
echo -e "${GREEN}─────────────────────────────────────────────────────────────────${NC}"
echo -e "  - The CLIENT request body was identical for both calls."
echo -e "  - The gateway's ${YELLOW}backend.ai.overrides${NC} forces ${YELLOW}tools: []${NC} +"
echo -e "    ${YELLOW}tool_choice: \"none\"${NC} before the request leaves the gateway."
echo -e "  - Use case: stop a misbehaving app from invoking tools you"
echo -e "    haven't approved, without changing the app's source code."
echo ""
echo -e "${YELLOW}Policy APPLIED. Inspect both responses above, then press Enter to revert.${NC}"
prompt_continue "Press Enter to tear down and exit"
