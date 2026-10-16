#!/bin/bash
# Pillar 1 · Catalog & Discovery — Case 3: Browse the registry web UI.
#
# What it shows
#   The registry's built-in web UI (served by the same server on port
#   12121, at the root path). The presenter walks through catalog
#   browse, search, the resource detail view, and the live agent/MCP
#   instances pane. Three demo personas are listed so the presenter can
#   log in as admin/writer/reader and show the RBAC difference live.
#
# This script just sets up the port-forward and opens a browser — no
# mutations, no cleanup beyond the port-forward.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

trap '_cleanup_portforwards' EXIT

demo_header "Pillar 1 · Catalog & Discovery — Registry web UI"

ensure_registry_portforward
UI_URL="${REGISTRY_URL:-http://localhost:12121}"

demo_step "Open the registry UI"
echo -e "  ${BOLD}${UI_URL}/${NC}              catalog browse + search"
echo -e "  ${BOLD}${UI_URL}/are/instances/${NC}  live agent + MCP instances"
echo -e "  ${BOLD}${UI_URL}/are/tracing${NC}      request traces"
echo ""
echo -e "${CYAN}Log in with one of the demo users (Keycloak realm '${KEYCLOAK_REALM}'):${NC}"
echo -e "  ${DEMO_USER_ADMIN:-admin-user}  (password: DEMO_USER_ADMIN_PASSWORD in .envrc)   (group=admins  → superuser)"
echo -e "  ${DEMO_USER_WRITER:-writer-user} (password: DEMO_USER_WRITER_PASSWORD in .envrc)  (group=writers)"
echo -e "  ${DEMO_USER_READER:-reader-user} (password: DEMO_USER_READER_PASSWORD in .envrc)  (group=readers)"

if command -v open >/dev/null 2>&1; then
  open "${UI_URL}/" 2>/dev/null || true
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "${UI_URL}/" 2>/dev/null || true
fi

prompt_continue "Walk the catalog in the browser — press Enter when done"
