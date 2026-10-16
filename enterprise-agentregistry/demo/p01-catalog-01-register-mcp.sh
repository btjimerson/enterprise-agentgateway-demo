#!/bin/bash
# Pillar 1 · Catalog & Discovery — Case 1: Register an MCP server.
#
# What it shows
#   The presenter scaffolds a Python MCP server with `arctl init mcp`
#   and registers it in the catalog with `arctl apply -f mcp.yaml`.
#   The scaffold uses the fastmcp/python framework; applying the
#   generated mcp.yaml catalogs the server's metadata + declarative
#   spec without us having to build, load, and deploy a container at
#   demo time — the catalog entry is the story here. Building and
#   deploying that image is the deploy-* pillar.
#
# Why this flow
#   The arctl CLI you're demoing IS the tool that creates the thing
#   you're demoing. `arctl init` emits a ready-to-edit declarative
#   project (mcp.yaml in the ar.dev/v1alpha1 format); `arctl apply`
#   is the single verb for getting any resource into the registry.
#
# Steps
#   1. `arctl init mcp <name> --framework fastmcp --language python`
#   2. Show the generated mcp.yaml — narrative moment for the presenter.
#   3. `arctl apply -f mcp.yaml` — register it in the catalog.
#   4. `arctl get mcp` — see it in the catalog.
#   5. `arctl get mcp <name> -o yaml` — see the stored spec.
#   6. Cleanup: `arctl delete mcp <name>` + rm workdir.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

require_arctl
require_cmds jq

# The registry catalogs MCP servers by a BARE DNS-1123 name — it does NOT
# namespace them. arctl rejects an org/name ref (e.g. "enterprise-ar-demo/echomcp")
# with a DNS-1123 error on `init` and "resource not found" on `get`/`delete`.
MCP_NAME="echomcp"
MCP_REF="${MCP_NAME}"
WORKDIR="$(mktemp -d -t enterprise-ar-mcp-XXXXXX)"

cleanup() {
  if [ "${DEMO_KEEP:-0}" = "1" ]; then
    demo_step "Cleanup — keeping ${MCP_REF} registered (DEMO_KEEP=1); removing scaffold only"
    rm -rf "${WORKDIR}"
    return
  fi
  demo_step "Cleanup — deregistering MCP server + removing scaffold"
  "${ARCTL}" delete mcp "${MCP_REF}" 2>/dev/null || true
  rm -rf "${WORKDIR}"
}
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 1 · Catalog & Discovery — Register an MCP server"

ensure_registry_portforward

demo_step "Scaffold a new fastmcp/python MCP server with arctl init"
echo "  arctl init mcp ${MCP_REF} \\"
echo "    --framework fastmcp --language python \\"
echo "    --output-dir ${WORKDIR}"
prompt_continue "Run the scaffold"
"${ARCTL}" init mcp "${MCP_REF}" \
  --framework fastmcp --language python \
  --output-dir "${WORKDIR}"

demo_step "Inspect the scaffolded project"
echo ""
echo -e "${CYAN}--- scaffold structure ---${NC}"
find "${WORKDIR}" -maxdepth 3 -type f 2>/dev/null | head -20
MCP_YAML=$(find "${WORKDIR}" -name mcp.yaml -type f 2>/dev/null | head -1)
if [ -n "${MCP_YAML}" ]; then
  show_file "${MCP_YAML}"
else
  echo -e "${YELLOW}  (no mcp.yaml found in the scaffold — check 'arctl init mcp --help')${NC}"
fi
prompt_continue "Read the generated declarative spec"

demo_step "Register the MCP server into the catalog (arctl apply)"
echo "  arctl apply -f ${MCP_YAML}"
prompt_continue "Run the apply"
"${ARCTL}" apply -f "${MCP_YAML}"

demo_step "List all MCP servers in the catalog"
echo "  arctl get mcp"
"${ARCTL}" get mcp

demo_step "Show the stored spec for the registered server"
echo "  arctl get mcp ${MCP_REF} -o yaml"
prompt_continue
"${ARCTL}" get mcp "${MCP_REF}" -o yaml

prompt_continue "Demo complete — press Enter to clean up"
