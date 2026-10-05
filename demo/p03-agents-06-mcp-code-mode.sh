#!/bin/bash
# Pillar 3 · Case 6: MCP Code mode (agentgateway 2026.6.3).  # version-literal-ok
#
# ─────────────────────────────────────────────────────────────────────
# WHY THIS PATTERN
# ─────────────────────────────────────────────────────────────────────
# Some workflows need MANY tool calls, and the intermediate results
# (raw HTML, large JSON) blow up the model's context if every call
# round-trips through the model. Code mode exposes a single tool,
# run_code: the model submits JavaScript that calls the upstream MCP
# tools directly, the gateway runs it in an embedded sandbox, and ONLY
# the script's final return value comes back. The model composes a whole
# pipeline in one turn and sees only the projected result.
#
# The run_code tool's description carries a typed JS API for each upstream
# tool the caller is authorized to use. codeMode.timeout caps execution.
#
# Self-contained: deploys the single-tool fetcher behind a Code-mode
# EnterpriseAgentgatewayBackend on /mcp/code, shows run_code is the only
# tool, then runs a script that fetches a URL and returns a small
# projection (never the full HTML). Torn down on exit.
#
# Docs: https://docs.solo.io/agentgateway/latest/mcp/tool-mode/code-mode/

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

FETCHER="${MANIFESTS_DIR}/mcp-website-fetcher.yaml"
BACKEND="${MANIFESTS_DIR}/backend-mcp-code.yaml"
MCP_PATH="/mcp/code"

cleanup() {
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" delete -f "${BACKEND}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" delete -f "${FETCHER}" --ignore-not-found >/dev/null 2>&1 || true
}
trap 'cleanup; _cleanup_portforwards; rm -rf "${TMP:-}"' EXIT

print_overview() {
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  Why Code mode${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo "  Multi-call workflows flood the model's context with intermediate"
  echo -e "  results. ${YELLOW}toolMode: Code${NC} exposes one tool, run_code: the model"
  echo "  writes JavaScript that calls the upstream tools in a sandbox, and"
  echo "  only the script's return value comes back. One turn, tiny context."
  echo ""
  cat <<'EOF'
   client ── tools/list ──▶ [ run_code ]   (typed JS API in its description)
          ── run_code("const r = await fetch({url}); ({len:String(r).length})")
                       ──▶ sandbox runs it upstream ──▶ only {len} returns
EOF
  echo ""
  echo -e "${CYAN}  Steps: deploy a 1-tool MCP server, then ${YELLOW}①${NC} handshake,"
  echo -e "${CYAN}  ${YELLOW}②${NC} tools/list (only run_code), ${YELLOW}③${NC} run_code a script.${NC}"
  echo ""
}

demo_header "Pillar 3 · Multi-Agent & Tool Workflows — MCP Code Mode"
print_overview
prompt_continue "Press Enter to start."

demo_step "1. Deploy a single-tool MCP server (fetch) behind a Code-mode backend on ${MCP_PATH}"
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

demo_step "② tools/list — expect ONLY run_code"
curl -sS -o "${TMP}/list" -X POST "${GATEWAY_URL}${MCP_PATH}" \
  -H "Accept: ${ACCEPT}" -H "Content-Type: application/json" -H "Mcp-Session-Id: ${SESSION}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
mcp_first_json "${TMP}/list" | jq -r '.result.tools[].name' | sort | sed 's/^/  /'

demo_step "③ run_code — a JS script fetches a URL and returns only a small projection"
echo -e "${CYAN}# script: const r = await fetch({url:'https://example.com'}); ({first120:String(r).slice(0,120), length:String(r).length})${NC}"
curl -sS -o "${TMP}/run" -X POST "${GATEWAY_URL}${MCP_PATH}" \
  -H "Accept: ${ACCEPT}" -H "Content-Type: application/json" -H "Mcp-Session-Id: ${SESSION}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_code","arguments":{"code":"const r = await fetch({url: \"https://example.com\"}); ({first120: String(r).slice(0,120), length: String(r).length})"}}}'
mcp_first_json "${TMP}/run" | jq -c '.result.structuredContent' 2>/dev/null | sed 's/^/  result: /'

echo ""
echo -e "${GREEN}The model submitted one script and got back only the projected fields —${NC}"
echo -e "${GREEN}the full page never entered its context. Multi-call workflows collapse${NC}"
echo -e "${GREEN}into a single run_code turn, executed in the gateway's sandbox.${NC}"
echo -e "${YELLOW}Self-contained — exiting removes the server, backend and route.${NC}"
prompt_continue "Press Enter to tear down and exit"
