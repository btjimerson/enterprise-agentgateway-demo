#!/bin/bash
# Pillar 2 · Secure Access — Case 2: RBAC — admin vs writer vs reader.
#
# What it shows
#   The registry derives RBAC roles from the OIDC `Groups` claim
#   (chart oidc.roleClaim=Groups, oidc.superuserRole=admins). Three
#   personas, three group memberships, three permission tiers:
#     - admin-user  (Groups: admins)  → superuser: full read + write.
#     - writer-user (Groups: writers) → non-superuser.
#     - reader-user (Groups: readers) → non-superuser.
#   We mint a token per user (ROPG) and run the same read + write
#   operations as each, showing who is allowed and who is denied.
#
# RBAC model
#   The registry extracts a role from the OIDC role claim (oidc.roleClaim,
#   default Groups). Two tiers:
#     - Superuser (oidc.superuserRole=admins) — bypasses all policy, full access.
#     - Every other role — NO access until an AccessPolicy (kind: AccessPolicy,
#       ar.dev/v1alpha1) grants it specific actions on specific resource kinds.
#   So three real tiers need policies: admins (superuser, no policy needed),
#   writers (read + write via accesspolicy-writers.yaml), readers (read-only via
#   accesspolicy-readers.yaml). This demo applies those policies (as admin) and
#   then shows each persona hitting the resulting allow/deny.
#
# Steps
#   1. Scaffold a valid mcp.yaml (so writes fail on AUTHZ, not schema).
#   2. As admin: apply the writers + readers AccessPolicies.
#   3. As each user: decode the Groups claim, then read + attempt write.
#   4. Cleanup: delete the test entry + the AccessPolicies (as admin).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

require_arctl
require_cmds jq

# MCP servers are cataloged by a BARE DNS-1123 name — the registry does not
# namespace them (arctl rejects an org/name ref on init and get/delete).
MCP_NAME="rbac-test"
MCP_REF="${MCP_NAME}"
WORKDIR="$(mktemp -d -t enterprise-ar-rbac-XXXXXX)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
POLICY_WRITERS="${MANIFESTS_DIR}/security/accesspolicy-writers.yaml"
POLICY_READERS="${MANIFESTS_DIR}/security/accesspolicy-readers.yaml"

cleanup() {
  demo_step "Cleanup — removing the RBAC test entry + AccessPolicies (as admin) + workdir"
  arctl_as "${DEMO_USER_ADMIN:-admin-user}" "${DEMO_USER_ADMIN_PASSWORD:?set DEMO_USER_ADMIN_PASSWORD in .envrc (see .envrc.sample)}" \
    -- delete mcp "${MCP_REF}" 2>/dev/null || true
  arctl_as "${DEMO_USER_ADMIN:-admin-user}" "${DEMO_USER_ADMIN_PASSWORD:?set DEMO_USER_ADMIN_PASSWORD in .envrc (see .envrc.sample)}" \
    -- delete accesspolicy writers 2>/dev/null || true
  arctl_as "${DEMO_USER_ADMIN:-admin-user}" "${DEMO_USER_ADMIN_PASSWORD:?set DEMO_USER_ADMIN_PASSWORD in .envrc (see .envrc.sample)}" \
    -- delete accesspolicy readers 2>/dev/null || true
  rm -rf "${WORKDIR}"
}
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 2 · Secure Access — RBAC reader vs writer vs admin"

ensure_registry_portforward
ensure_keycloak_portforward

demo_step "Scaffold a valid MCP spec so writes fail on AUTHZ, not schema"
"${ARCTL}" init mcp "${MCP_REF}" \
  --framework fastmcp --language python \
  --output-dir "${WORKDIR}" >/dev/null 2>&1 || true
MCP_YAML=$(find "${WORKDIR}" -name mcp.yaml -type f 2>/dev/null | head -1)
if [ -z "${MCP_YAML}" ]; then
  echo -e "${RED}  Could not scaffold an mcp.yaml — aborting RBAC demo.${NC}" >&2
  exit 1
fi
echo -e "${GREEN}  spec: ${MCP_YAML}${NC}"

demo_step "As admin: define the AccessPolicies (non-superuser roles have NO access without one)"
echo -e "${CYAN}  writers → read + write; readers → read-only. principals[].name matches the Groups claim.${NC}"
show_file "${POLICY_WRITERS}"
show_file "${POLICY_READERS}"
prompt_continue "Apply both AccessPolicies as admin"
arctl_as "${DEMO_USER_ADMIN:-admin-user}" "${DEMO_USER_ADMIN_PASSWORD:?set DEMO_USER_ADMIN_PASSWORD in .envrc (see .envrc.sample)}" \
  -- apply -f "${POLICY_WRITERS}" \
  || echo -e "${YELLOW}  (writers policy apply failed — the writer's write will be denied below)${NC}"
arctl_as "${DEMO_USER_ADMIN:-admin-user}" "${DEMO_USER_ADMIN_PASSWORD:?set DEMO_USER_ADMIN_PASSWORD in .envrc (see .envrc.sample)}" \
  -- apply -f "${POLICY_READERS}" \
  || echo -e "${YELLOW}  (readers policy apply failed)${NC}"

# run_as <label> <user> <pass> — decode Groups, then read + attempt write.
run_as() {
  local label="$1" user="$2" pass="$3" token
  demo_step "Persona: ${label}  (user=${user})"
  token=$(get_jwt "${user}" "${pass}") || { echo -e "${RED}  token mint failed${NC}"; return; }
  echo -e "${CYAN}  Groups claim:${NC} $(jwt_decode "${token}" | jq -c '.Groups // .groups // "(none)"')"

  echo -e "${YELLOW}  READ  → arctl get mcp${NC}"
  if arctl_as "${user}" "${pass}" -- get mcp >/dev/null 2>&1; then
    echo -e "${GREEN}    allowed${NC}"
  else
    echo -e "${RED}    denied${NC}"
  fi

  echo -e "${YELLOW}  WRITE → arctl apply -f mcp.yaml${NC}"
  if arctl_as "${user}" "${pass}" -- apply -f "${MCP_YAML}" >/tmp/rbac-write.log 2>&1; then
    echo -e "${GREEN}    allowed (registered ${MCP_REF})${NC}"
  else
    echo -e "${RED}    denied:${NC} $(grep -iE 'forbidden|denied|permission|403|unauthorized' /tmp/rbac-write.log | head -1)"
  fi
}

run_as "reader (read-only group)" "${DEMO_USER_READER:-reader-user}" "${DEMO_USER_READER_PASSWORD:?set DEMO_USER_READER_PASSWORD in .envrc (see .envrc.sample)}"
prompt_continue
run_as "writer" "${DEMO_USER_WRITER:-writer-user}" "${DEMO_USER_WRITER_PASSWORD:?set DEMO_USER_WRITER_PASSWORD in .envrc (see .envrc.sample)}"
prompt_continue
run_as "admin (superuser)" "${DEMO_USER_ADMIN:-admin-user}" "${DEMO_USER_ADMIN_PASSWORD:?set DEMO_USER_ADMIN_PASSWORD in .envrc (see .envrc.sample)}"

echo ""
echo -e "${CYAN}Takeaway: same call, different outcome by Groups claim — admins (superuser)${NC}"
echo -e "${CYAN}write freely; writers read + write via the writers AccessPolicy; readers are${NC}"
echo -e "${CYAN}read-only. Non-superuser permissions are declarative AccessPolicy resources.${NC}"

prompt_continue "Demo complete — press Enter to clean up"
