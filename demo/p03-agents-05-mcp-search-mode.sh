#!/bin/bash
# Pillar 3 · Case 5: MCP Search mode (agentgateway 2026.6.3).  # version-literal-ok
#
# ─────────────────────────────────────────────────────────────────────
# WHY THIS PATTERN
# ─────────────────────────────────────────────────────────────────────
# An MCP backend can front dozens or hundreds of upstream tools. If the
# gateway hands the whole catalog to the model on every request, it burns
# context and degrades tool selection. Search mode replaces the full tool
# list with just TWO meta tools:
#   - get_tool(name)          → look up a tool's description + input schema
#   - invoke_tool(name, args) → call the tool by name
# The model discovers tools on demand instead of ingesting the catalog.
# Authorization still applies: get_tool only returns tools the caller may use.
#
# This demo is self-contained: it deploys a single-tool MCP server
# (mcp-website-fetcher, tool `fetch`) behind a Search-mode
# EnterpriseAgentgatewayBackend on /mcp/search, proves the client sees only
# the two meta tools, then discovers and invokes `fetch` through them.
# Everything is torn down on exit.
#
# Docs: https://docs.solo.io/agentgateway/latest/mcp/tool-mode/search-mode/

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

FETCHER="${MANIFESTS_DIR}/mcp-website-fetcher.yaml"
BACKEND="${MANIFESTS_DIR}/backend-mcp-search.yaml"
MCP_PATH="/mcp/search"

cleanup() {
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" delete -f "${BACKEND}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" delete -f "${FETCHER}" --ignore-not-found >/dev/null 2>&1 || true
}
trap 'cleanup; _cleanup_portforwards; rm -rf "${TMP:-}"' EXIT

print_overview() {
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  Why Search mode${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo "  A big tool catalog bloats the model's context and hurts tool"
  echo -e "  selection. ${YELLOW}toolMode: Search${NC} hides the catalog behind two meta"
  echo "  tools — get_tool (discover) and invoke_tool (call by name) — so"
  echo "  the model pulls only the tools it needs, when it needs them."
  echo "  RBAC still applies: get_tool only surfaces authorized tools."
  echo ""
  cat <<'EOF'
   client ── tools/list ──▶ [ get_tool, invoke_tool ]   (NOT the raw catalog)
          ── get_tool(fetch) ──▶ description + input schema
          ── invoke_tool(fetch,{url}) ──▶ upstream fetch result
EOF
  echo ""
  echo -e "${CYAN}  Steps: deploy a 1-tool MCP server, then ${YELLOW}①${NC} handshake,"
  echo -e "${CYAN}  ${YELLOW}②${NC} tools/list (2 meta tools), ${YELLOW}③${NC} get_tool,"
  echo -e "${CYAN}  ${YELLOW}④${NC} invoke_tool.${NC}"
  echo ""
}

demo_header "Pillar 3 · Multi-Agent & Tool Workflows — MCP Search Mode"
print_overview
prompt_continue "Press Enter to start."

demo_step "1. Deploy a single-tool MCP server (fetch) behind a Search-mode backend on ${MCP_PATH}"
show_file "${BACKEND}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" apply -f "${FETCHER}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" apply -f "${BACKEND}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" rollout status deploy/mcp-website-fetcher --timeout=120s
sleep 5

ensure_gateway_portforward
ACCEPT="application/json, text/event-stream"
TMP=$(mktemp -d)

demo_step "① MCP handshake — initialize + notifications/initialized (retried while xDS programs the new route)"
SESSION=$(mcp_init_session "${GATEWAY_URL}${MCP_PATH}")
if [ -z "${SESSION}" ]; then echo -e "${RED}ERROR: no Mcp-Session-Id returned (backend not ready).${NC}"; exit 1; fi
echo -e "${CYAN}# Mcp-Session-Id: ${SESSION}${NC}"

demo_step "② tools/list — expect ONLY get_tool + invoke_tool (the raw 'fetch' is hidden)"
curl -sS -o "${TMP}/list" -X POST "${GATEWAY_URL}${MCP_PATH}" \
  -H "Accept: ${ACCEPT}" -H "Content-Type: application/json" -H "Mcp-Session-Id: ${SESSION}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
mcp_first_json "${TMP}/list" | jq -r '.result.tools[].name' | sort | sed 's/^/  /'

demo_step "③ get_tool(fetch) — discover the upstream tool's schema on demand"
curl -sS -o "${TMP}/get" -X POST "${GATEWAY_URL}${MCP_PATH}" \
  -H "Accept: ${ACCEPT}" -H "Content-Type: application/json" -H "Mcp-Session-Id: ${SESSION}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_tool","arguments":{"name":"fetch"}}}'
mcp_first_json "${TMP}/get" | jq -c '.result.structuredContent.results[] | {name, tool_description}' 2>/dev/null | sed 's/^/  /'

demo_step "④ invoke_tool(fetch, {url}) — call the tool by name via the meta tool"
curl -sS -o "${TMP}/inv" -X POST "${GATEWAY_URL}${MCP_PATH}" \
  -H "Accept: ${ACCEPT}" -H "Content-Type: application/json" -H "Mcp-Session-Id: ${SESSION}" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"invoke_tool","arguments":{"name":"fetch","arguments":{"url":"https://example.com"}}}}'
first120=$(mcp_first_json "${TMP}/inv" | jq -r '.result.content[0].text' 2>/dev/null | head -c 120)
echo "  fetch(example.com) → ${first120}..."

echo ""
echo -e "${GREEN}The client only ever saw get_tool + invoke_tool, yet reached the upstream${NC}"
echo -e "${GREEN}fetch tool through them — the catalog stays out of the model's context.${NC}"
echo -e "${YELLOW}Self-contained — exiting removes the server, backend and route.${NC}"
prompt_continue "Press Enter to tear down and exit"
