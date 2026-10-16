#!/bin/bash
# Pillar 2 · Secure Access — Case 3: Rejected-request logging.
#
# What it shows
#   The registry rejects unauthorized access and logs it. We fire a request
#   with NO token (→ 401), plus a little authenticated activity, then surface
#   the server's structured "authentication failed" log lines.
#
#   HONEST SCOPE: v2026.7.0 added
#   structured control-plane audit events exported over OTLP (resource changes,
#   approval-workflow events, selected authz decisions). This script does NOT
#   consume them yet. What it shows is still the stdout signal: the server logs
#   AUTHN FAILURES (rejected requests) at warn, but does NOT log a per-action
#   trail of successful mutations to stdout, and there's no arctl/API audit
#   query surface. Usage + invocation analytics live in the bundled ClickHouse
#   (security/p05-obs-01-audit-insights.sh), fed by the OTel collector. So this case
#   shows the reliable signal (rejected requests) and points at ClickHouse for
#   the rest.
#
# Steps
#   1. Fire an unauthenticated request (no token) → 401 (deterministically logged).
#   2. A little authenticated activity (admin apply + delete).
#   3. Tail the server logs and surface the rejected-request lines.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

require_arctl
require_cmds jq kubectl curl

# MCP servers are cataloged by a BARE DNS-1123 name — the registry does not
# namespace them (arctl rejects an org/name ref on init and get/delete).
MCP_NAME="audit-test"
MCP_REF="${MCP_NAME}"
WORKDIR="$(mktemp -d -t enterprise-ar-audit-XXXXXX)"
REGISTRY_DEPLOY="agentregistry-enterprise-server"

cleanup() {
  demo_step "Cleanup — removing the test entry + workdir"
  arctl_as "${DEMO_USER_ADMIN:-admin-user}" "${DEMO_USER_ADMIN_PASSWORD:?set DEMO_USER_ADMIN_PASSWORD in .envrc (see .envrc.sample)}" \
    -- delete mcp "${MCP_REF}" 2>/dev/null || true
  rm -rf "${WORKDIR}"
}
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 2 · Secure Access — Rejected-request logging"

ensure_registry_portforward
ensure_keycloak_portforward
REG_URL="${REGISTRY_URL:-${ARCTL_API_BASE_URL:-http://localhost:12121}}"

demo_step "Scaffold a valid MCP spec for the authenticated activity"
"${ARCTL}" init mcp "${MCP_REF}" \
  --framework fastmcp --language python \
  --output-dir "${WORKDIR}" >/dev/null 2>&1 || true
MCP_YAML=$(find "${WORKDIR}" -name mcp.yaml -type f 2>/dev/null | head -1)
[ -z "${MCP_YAML}" ] && { echo -e "${RED}  scaffold failed${NC}" >&2; exit 1; }

demo_step "Fire an UNAUTHENTICATED request (no token) — the registry rejects + logs it"
echo "  curl ${REG_URL}/v0/mcpservers      # no Authorization header"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${REG_URL}/v0/mcpservers" 2>/dev/null || echo "000")
if [ "${CODE}" = "401" ]; then
  echo -e "${GREEN}    → HTTP ${CODE} Unauthorized (rejected before any policy — logged at warn)${NC}"
else
  echo -e "${YELLOW}    → HTTP ${CODE} (expected 401; the registry still logs the rejection)${NC}"
fi

demo_step "Some authenticated activity (admin apply + delete)"
arctl_as "${DEMO_USER_ADMIN:-admin-user}" "${DEMO_USER_ADMIN_PASSWORD:?set DEMO_USER_ADMIN_PASSWORD in .envrc (see .envrc.sample)}" \
  -- apply -f "${MCP_YAML}" >/dev/null 2>&1 \
  && echo -e "${GREEN}  admin apply ${MCP_REF}: ok${NC}" || echo -e "${RED}  admin apply: failed${NC}"
arctl_as "${DEMO_USER_ADMIN:-admin-user}" "${DEMO_USER_ADMIN_PASSWORD:?set DEMO_USER_ADMIN_PASSWORD in .envrc (see .envrc.sample)}" \
  -- delete mcp "${MCP_REF}" >/dev/null 2>&1 \
  && echo -e "${GREEN}  admin delete ${MCP_REF}: ok${NC}" || echo -e "${RED}  admin delete: failed${NC}"

sleep 2  # let the logger flush

demo_step "Surface the rejected-request lines from the registry server logs"
echo "  kubectl -n ${AGENTREGISTRY_NAMESPACE} logs deploy/${REGISTRY_DEPLOY} --since=120s | grep 'authentication failed'"
prompt_continue
LOGS=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
  logs "deploy/${REGISTRY_DEPLOY}" --since=120s 2>/dev/null || echo "")
echo "${LOGS}" | grep -iE 'authentication failed|unauthor|"level":"warn"' | tail -20 | while IFS= read -r line; do
  echo "${line}" | jq . 2>/dev/null || echo "${line}"
done
if ! echo "${LOGS}" | grep -qiE 'authentication failed|unauthor'; then
  echo -e "${YELLOW}  No rejection lines in the window — re-run; the unauthenticated request${NC}"
  echo -e "${YELLOW}  above logs one at warn (the server may buffer briefly).${NC}"
fi

echo ""
echo -e "${CYAN}Scope: the server logs REJECTED requests (authn failures). A full per-action${NC}"
echo -e "${CYAN}audit trail of successful mutations / authz decisions isn't logged to stdout at${NC}"
echo -e "${CYAN}this version (no arctl/API audit surface). Usage + invocation${NC}"
echo -e "${CYAN}analytics live in the bundled ClickHouse — see p05-obs-01-audit-insights.sh.${NC}"

prompt_continue "Demo complete — press Enter to clean up"
