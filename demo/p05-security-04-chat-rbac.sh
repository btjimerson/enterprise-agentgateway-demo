#!/bin/bash
# Pillar 5 · Case 4: CEL-based RBAC on /chat.
#
# Applies policy-jwt (required for RBAC to see claims) + policy-rbac-chat.
# The RBAC policy denies every request whose JWT preferred_username is
# "alice"; bob and everyone else pass through.
#
#   1. Request as alice  → HTTP 403 (RBAC deny)
#   2. Request as bob    → HTTP 200 (allowed)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_ALICE:=alice}"
: "${DEMO_USER_ALICE_PASSWORD:?set DEMO_USER_ALICE_PASSWORD in .envrc (see .envrc.sample)}"
: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

POLICY_JWT="${MANIFESTS_DIR}/policy-jwt.yaml"
POLICY_RBAC="${MANIFESTS_DIR}/policy-rbac-chat.yaml"

cleanup() {
  delete_and_wait "${POLICY_RBAC}"
  delete_and_wait "${POLICY_JWT}"
}
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 5 · Security — CEL-based /chat RBAC"

demo_step "1. Show the RBAC policy"
show_file "${POLICY_RBAC}"
prompt_continue

demo_step "2. Apply JWT + RBAC policies"
apply_and_wait "${POLICY_JWT}"
apply_and_wait "${POLICY_RBAC}"

ensure_gateway_portforward

USER_PROMPT="hi"
BODY=$(jq -n --arg p "${USER_PROMPT}" \
  '{model:"gpt-4o",messages:[{role:"user",content:$p}]}')

# fire_as: shows the user, fires the request as that user, color-codes
# the HTTP code, and prints a snippet of the response body. Lets the
# audience see WHO was rejected/allowed and what the gateway returned,
# not just a bare status code.
fire_as() {
  local user="$1" pass="$2" expect="$3"
  echo -e "${CYAN}# user:${NC} ${user}    ${CYAN}expecting:${NC} ${expect}"
  local token; token=$(get_jwt "${user}" "${pass}")
  local out; out=$(mktemp)
  local code
  code=$(curl -sS -o "${out}" -w "%{http_code}" --max-time 10 -X POST \
    "${GATEWAY_URL}/chat/v1/chat/completions" \
    -H "Authorization: Bearer ${token}" \
    -H "x-user-id: ${user}" \
    -H "Content-Type: application/json" \
    -d "${BODY}")
  case "${code}" in
    200) echo -e "  ${GREEN}→ HTTP ${code}${NC}" ;;
    403) echo -e "  ${GREEN}→ HTTP ${code} (denied — exactly what we want)${NC}" ;;
    *)   echo -e "  ${RED}→ HTTP ${code}${NC}" ;;
  esac
  if [ -s "${out}" ]; then
    if jq -e . "${out}" >/dev/null 2>&1; then
      jq '{model: (.model // null), content: (.choices[0].message.content // null), error: (.error // null)}' "${out}" 2>/dev/null \
        || head -c 200 "${out}"
    else
      head -c 200 "${out}"; echo
    fi
  fi
  rm -f "${out}"
}

say_prompt "${USER_PROMPT}"
echo ""

demo_step "3. Request as ${DEMO_USER_ALICE} — RBAC matches preferred_username==alice → Deny"
fire_as "${DEMO_USER_ALICE}" "${DEMO_USER_ALICE_PASSWORD}" "HTTP 403"
echo ""

demo_step "4. Request as ${DEMO_USER_BOB} — RBAC rule does not match → Allow"
fire_as "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}" "HTTP 200"

echo ""
echo -e "${GREEN}Same CEL engine that powers MCP tool RBAC — attaches to any HTTPRoute${NC}"
echo -e "${GREEN}and evaluates against jwt.* / request.headers[] / context vars.${NC}"
echo -e "${YELLOW}Policies APPLIED. Press Enter to revert.${NC}"
prompt_continue "Press Enter to tear down and exit"
