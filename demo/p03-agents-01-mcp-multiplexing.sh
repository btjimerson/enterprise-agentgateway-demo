#!/bin/bash
# Pillar 3 · Case 1: MCP multiplexing (federated MCP backend).
#
# ─────────────────────────────────────────────────────────────────────
# WHY THIS PATTERN
# ─────────────────────────────────────────────────────────────────────
# MCP clients (Claude Desktop, IDE plugins, agent frameworks) typically
# can only register ONE MCP server at a time. As an enterprise wiring
# up many tool servers, that's a non-starter — the platform team needs
# to surface 'all the tools the user is allowed to see' through one
# endpoint, regardless of how many backend MCP servers actually exist.
#
# The agentgateway's federated AgentgatewayBackend solves this: declare
# multiple upstream MCP servers under one backend resource, and the
# gateway acts as a single virtual MCP server. Clients see the UNION of
# every upstream server's tools, prefixed by source server name so
# names don't collide. To the client, it's one server.
#
# ─────────────────────────────────────────────────────────────────────
# FLOW DIAGRAM
# ─────────────────────────────────────────────────────────────────────
#
#                            ┌────────────────────────────┐
#                            │  /mcp HTTPRoute            │
#                            │  → mcp-federated backend   │
#                            └────────────┬───────────────┘
#                                         │ (gateway fans out)
#                       ┌─────────────────┼─────────────────┐
#                       ▼                                   ▼
#         ┌─────────────────────────┐         ┌─────────────────────────┐
#         │  mcp-server-everything  │         │  mcp-tools-extra        │
#         │  serves its OWN tools   │         │  serves its OWN tools   │
#         └─────────────────────────┘         └─────────────────────────┘
#
#  Client tools/list reply (union of both, name-prefixed):
#    mcp-server-everything-3001_echo
#    mcp-server-everything-3001_get-annotated-message
#    mcp-tools-extra-3001_<…>
#    …
#
# ─────────────────────────────────────────────────────────────────────
# MCP HANDSHAKE (why this script is 3 demo_steps not 1)
# ─────────────────────────────────────────────────────────────────────
# MCP streamable HTTP requires a session, established via:
#   ① POST /mcp method=initialize
#       → response carries Mcp-Session-Id header (the session ID we
#         capture and reuse on every subsequent request)
#   ② POST /mcp method=notifications/initialized (no body content;
#       acknowledges the server's capabilities — required by spec)
#   ③ tools/list / tools/call / etc, all with Mcp-Session-Id header
#
# The gateway's federated backend does the handshake to EACH upstream
# server transparently, then returns one merged response upstream-side.
# The client only sees a single session.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

trap '_cleanup_portforwards' EXIT

print_mcp_overview() {
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  Why MCP federation${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo "  MCP clients can typically register only ONE MCP server. To"
  echo "  surface tools from many servers under one endpoint, the"
  echo -e "  agentgateway exposes a ${YELLOW}federated AgentgatewayBackend${NC} that"
  echo "  fans out to multiple upstream MCP servers. Clients see the"
  echo "  UNION of every upstream's tools through one /mcp route."
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  Flow${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  cat <<'EOF'

                    ┌────────────────────────────┐
                    │   /mcp HTTPRoute           │
                    │   → mcp-federated backend  │
                    └────────────┬───────────────┘
                                 │ (gateway fans out)
              ┌──────────────────┼──────────────────┐
              ▼                                     ▼
   ┌─────────────────────────┐         ┌─────────────────────────┐
   │  mcp-server-everything  │         │  mcp-tools-extra        │
   │  serves its OWN tools   │         │  serves its OWN tools   │
   └─────────────────────────┘         └─────────────────────────┘

  Client gets ONE merged tools/list with name-prefixed entries:
    mcp-server-everything-3001_echo
    mcp-tools-extra-3001_<…>
    …

EOF
  echo -e "${CYAN}  MCP requires a session handshake first. Steps below:${NC}"
  echo -e "    ${YELLOW}①${NC} initialize → capture Mcp-Session-Id"
  echo -e "    ${YELLOW}②${NC} notifications/initialized (required by spec)"
  echo -e "    ${YELLOW}③${NC} tools/list → see the union"
  echo ""
}

demo_header "Pillar 3 · Multi-Agent & Tool Workflows — MCP Multiplexing"

print_mcp_overview
prompt_continue "Press Enter to start."

ensure_gateway_portforward
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")
ACCEPT="application/json, text/event-stream"
TMP=$(mktemp -d)
trap '_cleanup_portforwards; rm -rf "${TMP}"' EXIT

demo_step "① MCP initialize handshake — capture Mcp-Session-Id"
curl -sS -D "${TMP}/init-h" -o "${TMP}/init-b" -X POST "${GATEWAY_URL}/mcp" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: ${ACCEPT}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{
        "protocolVersion":"2024-11-05",
        "capabilities":{},
        "clientInfo":{"name":"demo-curl","version":"1.0"}}}' >/dev/null
SESSION=$(awk -v IGNORECASE=1 -F': ' 'tolower($1)=="mcp-session-id" {gsub(/\r/,"",$2); print $2; exit}' "${TMP}/init-h")
if [ -z "${SESSION}" ]; then
  echo -e "${RED}ERROR: no Mcp-Session-Id header returned.${NC}" >&2
  cat "${TMP}/init-h" >&2
  exit 1
fi
echo -e "${CYAN}# Mcp-Session-Id: ${SESSION}${NC}"

demo_step "② notifications/initialized (required by MCP spec)"
curl -sS -o /dev/null -X POST "${GATEWAY_URL}/mcp" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: ${ACCEPT}" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: ${SESSION}" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' || true

demo_step "③ tools/list — expect union of mcp-server-everything + mcp-tools-extra"
status=$(curl -sS -o "${TMP}/tools-b" -w "%{http_code}" -X POST "${GATEWAY_URL}/mcp" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: ${ACCEPT}" \
  -H "Content-Type: application/json" \
  -H "Mcp-Session-Id: ${SESSION}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
echo -e "${CYAN}# HTTP ${status}${NC}"

payload=$(mcp_first_json "${TMP}/tools-b")
if [ -z "${payload}" ]; then
  echo -e "${RED}# (non-JSON response)${NC}"
  cat "${TMP}/tools-b"
  exit 1
fi
echo "${payload}" | jq -r '.result.tools[].name' | sort

echo ""
echo -e "${GREEN}Names prefixed with mcp-server-everything-* and mcp-tools-extra-* confirm the federation.${NC}"
