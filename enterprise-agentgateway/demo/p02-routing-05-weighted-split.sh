#!/bin/bash
# Pillar 2 · Case 5: weighted load balancing across LLM backends.
#
# Applies a demo-only HTTPRoute at /chat-split that splits 80/20 between
# the OpenAI AgentgatewayBackend and mock-llm. Fires 20 requests and
# tallies how many hit each backend by looking at the `model` field in
# the response JSON. With 80/20 weights, expect ~16 gpt-4o responses
# and ~4 mock-llm-1 responses (probabilistic — small samples will vary).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

ROUTE="${MANIFESTS_DIR}/httproute-chat-weighted.yaml"
REQUESTS=20

cleanup() { delete_and_wait "${ROUTE}"; }
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 2 · LLM Routing — Weighted Split (80/20 openai/mock)"

demo_step "1. Show the HTTPRoute"
show_file "${ROUTE}"
prompt_continue

demo_step "2. Apply the route"
apply_and_wait "${ROUTE}"

demo_step "3. Fire ${REQUESTS} requests through /chat-split and tally by model field"
ensure_gateway_portforward
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")
declare -i openai=0 mock=0 other=0 errors=0
OUT=$(mktemp)

# Header for the per-request line: index, HTTP code, model, content snippet.
printf "${CYAN}  %-6s %-4s  %-26s  %s${NC}\n" "#" "HTTP" "model" "response"
printf "  %-6s %-4s  %-26s  %s\n" "------" "----" "--------------------------" \
  "------------------------------------------------"
for i in $(seq 1 ${REQUESTS}); do
  code=$(curl -sS -o "${OUT}" -w "%{http_code}" --max-time 10 -X POST \
    "${GATEWAY_URL}/chat-split/v1/chat/completions" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "x-user-id: ${DEMO_USER_BOB}" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}' || echo "000")

  # Index of the form "01/20" so columns line up.
  idx=$(printf "%02d/%02d" "${i}" "${REQUESTS}")

  if [ "${code}" != "200" ]; then
    errors=$((errors + 1))
    # Show the first ~60 chars of the error body so the failure mode
    # is visible (timeout / 401 / upstream-down / etc.).
    snippet=$(head -c 60 "${OUT}" 2>/dev/null | tr '\n' ' ')
    printf "${RED}  %-6s %-4s  %-26s  %s${NC}\n" \
      "${idx}" "${code}" "(error)" "${snippet}"
    continue
  fi

  # On 200, parse model + first content line.
  model=$(jq -r '.model // "—"' "${OUT}" 2>/dev/null)
  content=$(jq -r '.choices[0].message.content // ""' "${OUT}" 2>/dev/null \
    | tr '\n' ' ' | head -c 50)

  case "${model}" in
    gpt-*|openai*)
      openai=$((openai + 1))
      color="${GREEN}"
      ;;
    mock-*)
      mock=$((mock + 1))
      color="${CYAN}"
      ;;
    *)
      other=$((other + 1))
      color="${YELLOW}"
      ;;
  esac
  printf "${color}  %-6s %-4s  %-26s  %s${NC}\n" \
    "${idx}" "${code}" "${model}" "\"${content}\""
done
rm -f "${OUT}"
echo ""
echo -e "${CYAN}# Tally:${NC}"
echo -e "  ${GREEN}openai (gpt-*):   ${openai}${NC}"
echo -e "  ${CYAN}mock-llm:         ${mock}${NC}"
echo -e "  ${YELLOW}other/unknown:    ${other}${NC}"
echo -e "  ${RED}errors:           ${errors}${NC}"

echo ""
echo -e "${GREEN}Expected: roughly 16 openai + 4 mock-llm. Small runs are noisy.${NC}"
echo -e "${YELLOW}Route is currently APPLIED. Inspect state now, then press Enter to tear down.${NC}"
prompt_continue "Press Enter to tear down and exit"
