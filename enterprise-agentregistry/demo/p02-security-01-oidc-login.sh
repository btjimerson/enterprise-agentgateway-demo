#!/bin/bash
# Pillar 2 · Secure Access — Case 1: OIDC login via Keycloak.
#
# What it shows
#   No bearer token → 401 from the registry. A valid Keycloak token →
#   success. The JWT carries a `Groups` claim that the registry's RBAC
#   engine maps to roles (admins = superuser via the chart's
#   oidc.superuserRole=admins).
#
# Steps
#   1. Hit the registry API with NO Authorization header → 401.
#   2. Mint a fresh token for admin-user via Keycloak ROPG.
#   3. Decode the JWT — show iss, Groups, azp, aud.
#   4. `arctl user whoami` + `arctl get mcp` — authenticated, succeed.
#
# Companion demos:
#   - p02-security-02: reader vs writer vs admin RBAC tiers.
#   - p02-security-03: publish + audit-log via ClickHouse / registry logs.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

require_arctl
require_cmds jq curl

trap '_cleanup_portforwards' EXIT

demo_header "Pillar 2 · Secure Access — OIDC login"

ensure_registry_portforward
ensure_keycloak_portforward

demo_step "Unauthenticated request — no Authorization header → 401"
echo "  curl -s -o /dev/null -w '%{http_code}' ${REGISTRY_URL}/v0/mcpservers"
prompt_continue
CODE=$(curl -s -o /dev/null -w "%{http_code}" "${REGISTRY_URL}/v0/mcpservers" 2>/dev/null || echo "000")
if [ "${CODE}" = "401" ] || [ "${CODE}" = "403" ]; then
  echo -e "${GREEN}  HTTP ${CODE} — registry rejects anonymous access (expected).${NC}"
else
  echo -e "${YELLOW}  HTTP ${CODE} — expected 401/403; the registry may be configured for autoauth.${NC}"
fi

demo_step "Mint a fresh token for ${DEMO_USER_ADMIN:-admin-user} from Keycloak"
echo "  # Resource-owner password grant against the public ar-cli-password client."
echo "  curl -d grant_type=password -d client_id=${AR_CLI_PASSWORD_CLIENT_ID} \\"
echo "       -d username=${DEMO_USER_ADMIN:-admin-user} -d password=... \\"
echo "       ${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token"
prompt_continue
TOKEN=$(get_jwt "${DEMO_USER_ADMIN:-admin-user}" "${DEMO_USER_ADMIN_PASSWORD:?set DEMO_USER_ADMIN_PASSWORD in .envrc (see .envrc.sample)}")

demo_step "Decode the token — inspect the \`Groups\` claim + audience"
jwt_decode "${TOKEN}"

demo_step "Authenticated, direct REST — now succeeds"
echo "  curl -H 'Authorization: Bearer <token>' ${REGISTRY_URL}/v0/mcpservers → HTTP code"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${TOKEN}" "${REGISTRY_URL}/v0/mcpservers" 2>/dev/null || echo "000")
echo -e "${GREEN}  HTTP ${CODE}${NC}"

demo_step "Authenticated, via arctl (uses the cached login session)"
echo "  arctl user whoami"
prompt_continue
"${ARCTL}" user whoami || echo -e "${YELLOW}  (run ../04-install-arctl.sh to establish the session)${NC}"
echo "  arctl get mcp"
"${ARCTL}" get mcp

demo_step "Where this token flows across the three enterprise charts"
cat <<'EOF'
  Every pod that checks authn validates against the same Keycloak realm
  — same `iss`, same signing key, same group-membership mapper emitting
  the `Groups` claim. The OIDC config is NATIVE chart values
  (no post-install env-var patching):

  1. solo-enterprise-ui (management chart)
       Browser login. ui.backend.oidc.* / ui.frontend.oidc.* point at the
       your Keycloak (solo-ui-backend / solo-ui-frontend clients).

  2. kagent-controller (kagent-enterprise chart)
       oidc.issuer / oidc.clientId=kagent-backend chart values.

  3. agentregistry server (agentregistry-enterprise chart)
       oidc.issuer / oidc.clientId=ar-backend /
       oidc.publicClientId=solo-ui-frontend / oidc.roleClaim=Groups /
       oidc.superuserRole=admins. Any session whose Groups claim contains
       `admins` resolves to the superuser role.
EOF

prompt_continue "Demo complete — press Enter"
