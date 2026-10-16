#!/bin/bash
# Seed the Agent Registry with a believable synthetic catalog (agents + MCP
# servers) so the registry UI and arctl demos have realistic data to browse —
# without building or pulling anything. It registers the declarative specs in
# manifests/seed-catalog.yaml via `arctl apply` (the same path the catalog
# demos use); the registry stores the metadata only, and localhost:5001/* image
# refs are exempt from OCI-label validation, so no images/registries are needed.
#
# All seeded entries are `demo-` prefixed. Idempotent (arctl apply upserts);
# re-run any time. `--cleanup` removes them (arctl delete -f the same file).
#
# Prereqs: agentregistry installed (03-install-agentregistry.sh) + arctl
# (04-install-arctl.sh). Uses the ./arctl.sh wrapper, which port-forwards the
# registry server and mints a fresh OIDC admin token per call, so your .envrc
# must be sourced (KEYCLOAK_ISSUER, DEMO_USER_ADMIN, DEMO_USER_ADMIN_PASSWORD).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCTL_SH="${SCRIPT_DIR}/arctl.sh"
CATALOG="${SCRIPT_DIR}/manifests/seed-catalog.yaml"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'

MODE=seed
case "${1:-}" in
  --cleanup) MODE=cleanup ;;
  -h|--help) echo "Usage: $0 [--cleanup]"; exit 0 ;;
  "") ;;
  *) echo -e "${RED}Unknown arg: $1${NC}" >&2; exit 1 ;;
esac

[ -x "${ARCTL_SH}" ] || { echo -e "${RED}ERROR: ${ARCTL_SH} not found/executable.${NC}" >&2; exit 1; }
[ -f "${CATALOG}" ]  || { echo -e "${RED}ERROR: catalog not found at ${CATALOG}.${NC}" >&2; exit 1; }

count() { "${ARCTL_SH}" get "$1" 2>/dev/null | grep -c '^demo-'; }

if [ "${MODE}" = "cleanup" ]; then
  echo -e "${BLUE}Removing the seeded demo catalog (arctl delete -f)...${NC}"
  "${ARCTL_SH}" delete -f "${CATALOG}" 2>&1 | grep -viE 'zoxide|configuration issue|ensure that|filing an issue|Disable this' \
    | grep -iE 'deleted|not found|error|✓|✗' | sed 's/^/  /'
  echo -e "${GREEN}Cleanup complete. Remaining demo entries — agents: $(count agents), mcps: $(count mcps).${NC}"
  exit 0
fi

echo -e "${BLUE}Seeding the Agent Registry catalog from manifests/seed-catalog.yaml...${NC}"
OUT="$("${ARCTL_SH}" apply -f "${CATALOG}" 2>&1)"
echo "${OUT}" | grep -viE 'zoxide|configuration issue|ensure that|filing an issue|Disable this' \
  | grep -iE 'created|updated|error|✗' | sed 's/^/  /'
if echo "${OUT}" | grep -qiE 'error|✗|unauthor|forbidden'; then
  echo -e "${RED}Some entries failed. Check that .envrc is sourced and arctl can reach the registry:${NC}" >&2
  echo -e "${RED}  ${ARCTL_SH} user whoami${NC}" >&2
fi

echo ""
echo -e "${GREEN}Catalog seeded — agents: $(count agents), MCP servers: $(count mcps) (all 'demo-' prefixed).${NC}"
echo -e "${GREEN}Browse them in the Solo UI (Agent Registry) or with:${NC}"
echo -e "  ${CYAN:-}${ARCTL_SH##*/} get agents${NC}   /   ${ARCTL_SH##*/} get mcps"
echo -e "${YELLOW}Re-run to reseed; '$0 --cleanup' removes the demo catalog.${NC}"
