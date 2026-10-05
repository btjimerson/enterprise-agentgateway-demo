#!/bin/bash
# Pillar 3 · Case 7: Composable MCP (agentgateway 2026.6.3).  # version-literal-ok
#
# ─────────────────────────────────────────────────────────────────────
# WHY THIS PATTERN
# ─────────────────────────────────────────────────────────────────────
# A single agent action often needs data from several places — e.g. a
# user profile from one API and their repos from another. Normally you'd
# build and operate a custom MCP server to stitch those calls together.
# Composable MCP removes that: you declare a pipeline of HTTP/MCP steps
# directly on an EnterpriseAgentgatewayBackend, chained with CEL, and the
# gateway exposes the whole pipeline as ONE MCP tool. No custom code, no
# extra server to run.
#
# Each step's JSON response is captured in output.<step_name>; a final
# CEL `output` expression assembles the composite result the client sees.
#
# This demo exposes a `github-summary` tool: step `user` GETs a GitHub
# profile, step `repos` GETs their repositories, and `output` composes a
# one-line summary from both. Self-contained on /mcp/composable; torn down
# on exit.
#
# NOTE: the steps call the public GitHub API (egress + TLS origination).
# Unauthenticated GitHub is rate-limited (~60 req/hr); each call = 2 requests.
#
# Docs: https://docs.solo.io/agentgateway/latest/mcp/composable/

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

BACKEND="${MANIFESTS_DIR}/backend-mcp-composable.yaml"
MCP_PATH="/mcp/composable"
GH_USER="${GH_USER:-torvalds}"

cleanup() {
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" delete -f "${BACKEND}" --ignore-not-found >/dev/null 2>&1 || true
}
trap 'cleanup; _cleanup_portforwards; rm -rf "${TMP:-}"' EXIT

print_overview() {
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  Why Composable MCP${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo "  Combining several APIs into one agent tool usually means building"
  echo -e "  a custom MCP server. ${YELLOW}Composable MCP${NC} declares the pipeline on the"
  echo "  backend instead: an ordered list of HTTP/MCP steps chained with"
  echo "  CEL, exposed to clients as a single MCP tool. No custom code."
  echo ""
  cat <<'EOF'
   github-summary(name):
     step user  ── GET api.github.com/users/<name>        ─▶ output.user
     step repos ── GET api.github.com/users/<name>/repos   ─▶ output.repos
     output (CEL): "Hello " + output.user.login + "! You have "
                   + output.user.public_repos + " repos. A few: "
                   + output.repos.map(r, r.name).join(", ")
EOF
  echo ""
  echo -e "${CYAN}  Steps: deploy the composable backend, then ${YELLOW}①${NC} handshake,"
  echo -e "${CYAN}  ${YELLOW}②${NC} tools/list (one composite tool), ${YELLOW}③${NC} call it.${NC}"
  echo ""
}

demo_header "Pillar 3 · Multi-Agent & Tool Workflows — Composable MCP"
print_overview
prompt_continue "Press Enter to start."

demo_step "1. Deploy the composable backend (github-api + TLS policy + github-summary tool) on ${MCP_PATH}"
show_file "${BACKEND}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" apply -f "${BACKEND}"
sleep 8

ensure_gateway_portforward
ACCEPT="application/json, text/event-stream"
TMP=$(mktemp -d)

demo_step "① MCP handshake — initialize + notifications/initialized (retried while xDS programs the new route)"
SESSION=$(mcp_init_session "${GATEWAY_URL}${MCP_PATH}")
if [ -z "${SESSION}" ]; then echo -e "${RED}ERROR: no Mcp-Session-Id returned (backend not ready).${NC}"; exit 1; fi
echo -e "${CYAN}# Mcp-Session-Id: ${SESSION}${NC}"

demo_step "② tools/list — expect one composite tool: github-summary"
curl -sS -o "${TMP}/list" -X POST "${GATEWAY_URL}${MCP_PATH}" \
  -H "Accept: ${ACCEPT}" -H "Content-Type: application/json" -H "Mcp-Session-Id: ${SESSION}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
mcp_first_json "${TMP}/list" | jq -c '.result.tools[] | {name, inputSchema}' 2>/dev/null | sed 's/^/  /'

demo_step "③ Call github-summary(${GH_USER}) — one tool call, two upstream HTTP steps, CEL-assembled result"
curl -sS -o "${TMP}/call" -X POST "${GATEWAY_URL}${MCP_PATH}" \
  -H "Accept: ${ACCEPT}" -H "Content-Type: application/json" -H "Mcp-Session-Id: ${SESSION}" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"github-summary\",\"arguments\":{\"name\":\"${GH_USER}\"}}}"
result=$(mcp_first_json "${TMP}/call" | jq -r '.result.content[0].text' 2>/dev/null)
echo "  ${result:-<no result — GitHub rate limit or egress issue>}"

echo ""
echo -e "${GREEN}One MCP tool, assembled from two HTTP calls + a CEL expression — no custom${NC}"
echo -e "${GREEN}MCP server written or deployed. Steps can also call other MCP servers.${NC}"
echo -e "${YELLOW}Self-contained — exiting removes the backends, TLS policy and route.${NC}"
prompt_continue "Press Enter to tear down and exit"
