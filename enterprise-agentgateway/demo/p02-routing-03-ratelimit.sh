#!/bin/bash
# Pillar 2 · Case 3: per-user rate limit (5 req/min by x-user-id).
#
# Applies policy-jwt + policy-ratelimit + ratelimitconfig. Fires 10 requests
# back-to-back — first 5 should succeed (200), requests 6–10 should be
# rate-limited (429). Reverts on exit.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

POLICY_JWT="${MANIFESTS_DIR}/policy-jwt.yaml"
POLICY_RATELIMIT="${MANIFESTS_DIR}/policy-ratelimit.yaml"
RATELIMIT_CONFIG="${MANIFESTS_DIR}/ratelimitconfig.yaml"

cleanup() {
  delete_and_wait "${POLICY_RATELIMIT}"
  delete_and_wait "${RATELIMIT_CONFIG}"
  delete_and_wait "${POLICY_JWT}"
}
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 2 · LLM Routing — Rate Limit (5 req/min per x-user-id)"

demo_step "1. Show the policy + RateLimitConfig"
show_file "${POLICY_RATELIMIT}"
show_file "${RATELIMIT_CONFIG}"
prompt_continue

demo_step "2. Apply JWT + rate-limit policies"
apply_and_wait "${POLICY_JWT}"
apply_and_wait "${RATELIMIT_CONFIG}"
apply_and_wait "${POLICY_RATELIMIT}"

demo_step "3. Fire 10 requests back-to-back as ${DEMO_USER_BOB}"
ensure_gateway_portforward
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")
for i in $(seq 1 10); do
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "${GATEWAY_URL}/chat/v1/chat/completions" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "x-user-id: ${DEMO_USER_BOB}" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}')
  echo "  request $i: HTTP ${code}"
done

echo ""
echo -e "${GREEN}Expected: first 5 = 200, requests 6-10 = 429 (rate limited).${NC}"
echo -e "${YELLOW}Policies APPLIED. Inspect, then press Enter to revert.${NC}"
prompt_continue "Press Enter to tear down and exit"
