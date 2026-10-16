#!/bin/bash
# Pillar 3 · Case 2: MCP tool RBAC by JWT subject.
#
# Applies policy-jwt + policy-rbac-mcp. The RBAC policy reads the JWT's
# preferred_username claim and restricts what tools show up in tools/list:
#   - alice (mcp_scope=restricted) only sees tools ending in `_echo` or `_get-sum`
#   - bob   (mcp_scope=all)        sees every tool
# Reverts both policies on exit.

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
POLICY_RBAC="${MANIFESTS_DIR}/policy-rbac-mcp.yaml"

cleanup() {
  delete_and_wait "${POLICY_RBAC}"
  delete_and_wait "${POLICY_JWT}"
}
trap 'cleanup; _cleanup_portforwards; rm -rf "${TMP:-}"' EXIT

demo_header "Pillar 3 · Multi-Agent & Tool Workflows — MCP RBAC"

demo_step "1. Show the MCP RBAC policy"
show_file "${POLICY_RBAC}"
prompt_continue

demo_step "2. Apply JWT + MCP RBAC policies"
apply_and_wait "${POLICY_JWT}"
apply_and_wait "${POLICY_RBAC}"

ensure_gateway_portforward
ACCEPT="application/json, text/event-stream"
TMP=$(mktemp -d)

list_tools_for_user() {
  local user="$1" pass="$2"
  local token; token=$(get_jwt "${user}" "${pass}")

  curl -sS -D "${TMP}/${user}-init-h" -o "${TMP}/${user}-init-b" \
    -X POST "${GATEWAY_URL}/mcp" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: ${ACCEPT}" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{
          "protocolVersion":"2024-11-05",
          "capabilities":{},
          "clientInfo":{"name":"demo-curl","version":"1.0"}}}' >/dev/null
  local session
  session=$(awk -v IGNORECASE=1 -F': ' \
    'tolower($1)=="mcp-session-id" {gsub(/\r/,"",$2); print $2; exit}' \
    "${TMP}/${user}-init-h")
  if [ -z "${session}" ]; then
    echo "  (failed to initialize MCP session for ${user})"
    cat "${TMP}/${user}-init-h"
    return 1
  fi
  curl -sS -o /dev/null -X POST "${GATEWAY_URL}/mcp" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: ${ACCEPT}" \
    -H "Content-Type: application/json" \
    -H "Mcp-Session-Id: ${session}" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' || true

  local status
  status=$(curl -sS -o "${TMP}/${user}-tools" -w "%{http_code}" -X POST "${GATEWAY_URL}/mcp" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: ${ACCEPT}" \
    -H "Content-Type: application/json" \
    -H "Mcp-Session-Id: ${session}" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
  echo -e "${CYAN}# HTTP ${status}${NC}"

  local payload
  payload=$(mcp_first_json "${TMP}/${user}-tools")
  if [ -z "${payload}" ]; then
    echo "  (non-JSON response)"; cat "${TMP}/${user}-tools"; return 1
  fi
  echo "${payload}" | jq -r '.result.tools[].name' | sort
}

demo_step "3. tools/list as ${DEMO_USER_ALICE} (restricted)"
list_tools_for_user "${DEMO_USER_ALICE}" "${DEMO_USER_ALICE_PASSWORD}"

demo_step "4. tools/list as ${DEMO_USER_BOB} (unrestricted)"
list_tools_for_user "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}"

echo ""
echo -e "${GREEN}Expected: alice's list is a strict subset of bob's.${NC}"
echo -e "${YELLOW}Policies APPLIED. Inspect, then press Enter to revert.${NC}"
prompt_continue "Press Enter to tear down and exit"
