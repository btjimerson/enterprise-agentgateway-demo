#!/bin/bash
# Pillar 3 · Case 4: MCP rate limiting.
#
# Applies policy-ratelimit-mcp.yaml, which attaches the shared
# per-user-5-per-min RateLimitConfig to the /mcp HTTPRoute. Fires 8
# tools/list calls back-to-back; first 5 succeed, next 3 hit 429.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

POLICY="${MANIFESTS_DIR}/policy-ratelimit-mcp.yaml"
CONFIG="${MANIFESTS_DIR}/ratelimitconfig.yaml"

cleanup() {
  delete_and_wait "${POLICY}"
  # ratelimitconfig.yaml may also be used by the /chat ratelimit demo;
  # delete it safely — apply is idempotent and both demos apply it on
  # entry, so losing it here doesn't break the other demo.
  delete_and_wait "${CONFIG}"
}
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 3 · Multi-Agent & Tool Workflows — MCP Rate Limit"

demo_step "1. Show the RateLimitConfig + policy"
show_file "${CONFIG}"
show_file "${POLICY}"
prompt_continue

demo_step "2. Apply both"
apply_and_wait "${CONFIG}"
apply_and_wait "${POLICY}"

ensure_gateway_portforward
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")
ACCEPT="application/json, text/event-stream"
TMP=$(mktemp -d)
trap '_cleanup_portforwards; rm -rf "${TMP}"; cleanup' EXIT

demo_step "3. MCP handshake: initialize → capture Mcp-Session-Id"
curl -sS -D "${TMP}/init-h" -o "${TMP}/init-b" -X POST "${GATEWAY_URL}/mcp" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "x-user-id: ${DEMO_USER_BOB}" \
  -H "Accept: ${ACCEPT}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{
        "protocolVersion":"2024-11-05",
        "capabilities":{},
        "clientInfo":{"name":"demo-curl","version":"1.0"}}}' >/dev/null
SESSION=$(awk -v IGNORECASE=1 -F': ' 'tolower($1)=="mcp-session-id" {gsub(/\r/,"",$2); print $2; exit}' "${TMP}/init-h")
if [ -z "${SESSION}" ]; then
  echo -e "${RED}ERROR: no Mcp-Session-Id header returned${NC}" >&2
  cat "${TMP}/init-h" >&2
  exit 1
fi
curl -sS -o /dev/null -X POST "${GATEWAY_URL}/mcp" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "x-user-id: ${DEMO_USER_BOB}" \
  -H "Accept: ${ACCEPT}" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: ${SESSION}" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' || true

demo_step "4. Fire 8 tools/list calls back-to-back as ${DEMO_USER_BOB}"
for i in $(seq 1 8); do
  code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 -X POST "${GATEWAY_URL}/mcp" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "x-user-id: ${DEMO_USER_BOB}" \
    -H "Accept: ${ACCEPT}" \
    -H "Content-Type: application/json" \
    -H "Mcp-Session-Id: ${SESSION}" \
    -d '{"jsonrpc":"2.0","id":'${i}',"method":"tools/list","params":{}}')
  echo "  call ${i}: HTTP ${code}"
done

echo ""
echo -e "${GREEN}Expected: first 5 = 200, next 3 = 429 (budget exhausted — same per-user bucket${NC}"
echo -e "${GREEN}as the /chat rate-limit demo, so a client can't switch surfaces to get extra quota).${NC}"
echo -e "${YELLOW}Policy APPLIED. Press Enter to revert.${NC}"
prompt_continue "Press Enter to tear down and exit"
