#!/bin/bash
# Pillar 1 · Catalog & Discovery — Case: Shadow existing Microsoft Foundry agents.
#
# What it shows
#   Agentregistry DISCOVERING (shadowing) agents that already run in a Microsoft
#   Foundry project — the "see every agent across your CSPs without redeploying
#   them" value prop. The MicrosoftFoundry Runtime is discovery-ONLY: the
#   registry never deploys to Foundry; it lists the project's agents and surfaces
#   them as *Unmanaged* instances you can view/search (you can only interact with
#   agents the registry itself deployed).
#
#   New in agentregistry v2026.6.2 (server type `MicrosoftFoundry`). Auth is the
#   Entra client-credentials flow (scope https://ai.azure.com/.default); the
#   registry calls {projectEndpoint}/agents?api-version=v1.
#
#   CONFIG SHAPE CHANGED IN v2026.8.0. The auth block was restructured and the
#   old form is now rejected outright with:
#       ✗ Runtime/foundry failed: prepare: invalid input: auth.oidc is required
#   What moved:
#     config.tenantId          -> gone; expressed as config.auth.oidc.issuer,
#                                 https://login.microsoftonline.com/<tenant>/v2.0
#     config.clientId          -> config.auth.oidc.clientId
#     config.auth.clientSecretRef -> config.auth.oidc.clientSecretRef
#   `subscriptionId` / `resourceGroup` stay directly under `config`.
#
# Optional — gated on AZURE_FOUNDRY_* env (skips with a note when unset), like
# p03-deploy-02/03.
#
# Azure-side prerequisites (manual, one-time — none of this is automated):
#   1. Entra app registration (portal.azure.com → Microsoft Entra ID →
#      App registrations → New). Copy Application (client) ID + Directory
#      (tenant) ID; create a client secret and copy its value.
#        → AZURE_FOUNDRY_CLIENT_ID, AZURE_FOUNDRY_TENANT_ID, AZURE_FOUNDRY_CLIENT_SECRET
#   2. A Foundry PROJECT in ai.azure.com. Copy the PROJECT endpoint (not the
#      account endpoint, not a legacy hub connection string):
#        https://<account>.services.ai.azure.com/api/projects/<project>
#        → AZURE_FOUNDRY_PROJECT_ENDPOINT
#   3. Grant the app the "Foundry User" role ON THE PROJECT resource (Access
#      control (IAM) on the project, not just the resource group/subscription).
#   4. Create at least one agent in the project — discovery only shows agents
#      that already exist.
# Then set the env in .envrc and run ./05-register-runtimes.sh (or this script,
# which registers the Runtime itself if it's missing).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

trap '_cleanup_portforwards' EXIT

demo_header "Pillar 1 · Catalog & Discovery — Shadow Microsoft Foundry agents"

FOUNDRY_NAME="${AZURE_FOUNDRY_RUNTIME_NAME:-foundry}"
FOUNDRY_SECRET="microsoft-foundry-creds"

# --- gate: skip gracefully when Foundry env is not configured ---------------
if [ -z "${AZURE_FOUNDRY_TENANT_ID:-}" ] || [ -z "${AZURE_FOUNDRY_CLIENT_ID:-}" ] \
   || [ -z "${AZURE_FOUNDRY_CLIENT_SECRET:-}" ] || [ -z "${AZURE_FOUNDRY_PROJECT_ENDPOINT:-}" ]; then
  echo ""
  echo -e "${YELLOW}Skipping — Microsoft Foundry discovery is not configured.${NC}"
  echo -e "${YELLOW}Set these in .envrc (see this script's header for the Azure-side setup):${NC}"
  echo -e "    AZURE_FOUNDRY_TENANT_ID, AZURE_FOUNDRY_CLIENT_ID,"
  echo -e "    AZURE_FOUNDRY_CLIENT_SECRET, AZURE_FOUNDRY_PROJECT_ENDPOINT"
  echo ""
  echo -e "${CYAN}What this demo would show: agents already running in a Foundry${NC}"
  echo -e "${CYAN}project, auto-discovered and listed as Unmanaged instances.${NC}"
  exit 0
fi

require_arctl
require_cmds jq
ensure_registry_portforward

# --- ensure the Secret + Runtime exist (idempotent; self-contained) ---------
demo_step "Store the Entra client secret via the registry Secret API"
echo -e "${CYAN}  Secret '${FOUNDRY_SECRET}' (key: clientSecret) — value is write-only.${NC}"
arctl_apply <<EOF
apiVersion: ar.dev/v1alpha1
kind: Secret
metadata:
  name: ${FOUNDRY_SECRET}
spec:
  type: Opaque
  stringData:
    clientSecret: "${AZURE_FOUNDRY_CLIENT_SECRET}"
EOF

demo_step "Register the MicrosoftFoundry Runtime (points at the Foundry project)"
FOUNDRY_OPT=""
[ -n "${AZURE_FOUNDRY_SUBSCRIPTION_ID:-}" ] && FOUNDRY_OPT+=$'\n'"    subscriptionId: \"${AZURE_FOUNDRY_SUBSCRIPTION_ID}\""
[ -n "${AZURE_FOUNDRY_RESOURCE_GROUP:-}" ]  && FOUNDRY_OPT+=$'\n'"    resourceGroup: \"${AZURE_FOUNDRY_RESOURCE_GROUP}\""
arctl_apply <<EOF
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata:
  name: ${FOUNDRY_NAME}
spec:
  type: MicrosoftFoundry
  config:
    projectEndpoint: "${AZURE_FOUNDRY_PROJECT_ENDPOINT}"${FOUNDRY_OPT}
    auth:
      oidc:
        issuer: "https://login.microsoftonline.com/${AZURE_FOUNDRY_TENANT_ID}/v2.0"
        clientId: "${AZURE_FOUNDRY_CLIENT_ID}"
        clientSecretRef:
          name: ${FOUNDRY_SECRET}
          key: clientSecret
EOF

# --- show the sync status ----------------------------------------------------
demo_step "Wait for the discovery sync, then show the Runtime status"
echo -e "${CYAN}  (apply triggers a sync; give it a few seconds to call Foundry)${NC}"
for _ in $(seq 1 12); do
  status="$("${ARCTL}" get runtime "${FOUNDRY_NAME}" -o yaml 2>/dev/null \
            | grep -iE 'lastSync(Status|Error)|status:|reason:' | head -8)"
  echo "${status}" | grep -qiE 'succeed|synced|ready' && break
  sleep 2
done
echo ""
"${ARCTL}" get runtime "${FOUNDRY_NAME}" -o yaml 2>/dev/null \
  | sed -n '/status:/,$p' | head -30 \
  || echo -e "${YELLOW}  (could not read runtime status)${NC}"

# --- discovered instances in the UI -----------------------------------------
UI_URL="${REGISTRY_URL:-http://localhost:12121}"
demo_step "View the discovered Foundry agents as Unmanaged instances"
echo -e "  ${BOLD}${UI_URL}/are/instances/${NC}"
echo -e "  In the ${BOLD}Managed${NC} drop-down choose ${BOLD}Unmanaged${NC} (or ${BOLD}Managed and Unmanaged${NC})."
echo -e "  Or open ${BOLD}Runtimes → ${FOUNDRY_NAME}${NC} → discovered instances."
echo -e "  Each agent shows provider metadata: remote ID, version, kind, model,"
echo -e "  tools, and last-seen time. View/search only — Foundry agents can't be"
echo -e "  invoked from here (the registry didn't deploy them)."

if command -v open >/dev/null 2>&1; then
  open "${UI_URL}/are/instances/" 2>/dev/null || true
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "${UI_URL}/are/instances/" 2>/dev/null || true
fi

echo ""
echo -e "${CYAN}If no agents appear:${NC}"
echo -e "  • The Runtime must use the Foundry PROJECT endpoint (not the account endpoint)."
echo -e "  • The Entra app needs the 'Foundry User' role ON THE PROJECT resource."
echo -e "  • The project must contain at least one agent."
echo -e "  • Check server logs for 'foundry: API returned' or 'resolve client secret':"
echo -e "      kubectl -n ${AGENTREGISTRY_NAMESPACE} logs deploy/${REGISTRY_SVC} | grep -i foundry"

prompt_continue "Review the discovered Foundry instances in the browser — press Enter when done"
