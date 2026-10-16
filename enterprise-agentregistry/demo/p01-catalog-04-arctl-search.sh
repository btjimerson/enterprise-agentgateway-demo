#!/bin/bash
# Pillar 1 · Catalog & Discovery — Case 4: CLI-based discovery via arctl.
#
# What it shows
#   Everything the registry UI shows, but in a shell — useful for CI/CD
#   integrations and scripts that pick an MCP server or agent at deploy
#   time.
#
# Steps
#   1. `arctl get mcp` — every registered MCP server.
#   2. `arctl get agents` — every registered agent.
#   3. `arctl get all` — all resource kinds at once.
#   4. Free-text filter via grep (no native --search flag).
#   5. `arctl get mcp <name> -o yaml` — full stored spec.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

require_arctl

demo_header "Pillar 1 · Catalog & Discovery — arctl search"

ensure_registry_portforward

demo_step "List every registered MCP server"
echo "  arctl get mcp"
prompt_continue
"${ARCTL}" get mcp

demo_step "List every registered agent"
echo "  arctl get agents"
prompt_continue
"${ARCTL}" get agents

demo_step "List every resource kind at once"
echo "  arctl get all"
prompt_continue
"${ARCTL}" get all 2>&1 || echo -e "${YELLOW}  ('get all' unsupported on this build — list kinds individually)${NC}"

demo_step "Free-text search — pipe through grep (no native --search flag)"
echo "  arctl get mcp | grep -i echo"
prompt_continue
"${ARCTL}" get mcp 2>/dev/null | grep -i echo \
  || echo -e "${YELLOW}  (no matches — pre-populate with: DEMO_KEEP=1 ./p01-catalog-01-register-mcp.sh)${NC}"

demo_step "Fetch the full stored spec for one MCP entry"
# First column of `arctl get mcp` is the name. Skip the header row.
FIRST_MCP=$("${ARCTL}" get mcp 2>/dev/null | awk 'NR>1 && $1 != "" {print $1; exit}')
if [ -n "${FIRST_MCP}" ] && [ "${FIRST_MCP}" != "NAME" ]; then
  echo "  arctl get mcp ${FIRST_MCP} -o yaml"
  prompt_continue
  "${ARCTL}" get mcp "${FIRST_MCP}" -o yaml 2>&1 \
    || echo -e "${YELLOW}  (try -o json or 'arctl get --help')${NC}"
else
  echo -e "${YELLOW}  (no MCP servers registered — pre-populate with: DEMO_KEEP=1 ./p01-catalog-01-register-mcp.sh)${NC}"
fi

prompt_continue "Demo complete — press Enter"
