#!/bin/bash

# Open the agentregistry demo UIs over localhost port-forwards.
#
# Keycloak is an EXTERNAL server (HTTPS), so its login cookies are
# already fine. The UIs run in-cluster and set their own Secure;SameSite=None
# session cookie, which a browser only stores in a secure context — so we reach
# them via http://localhost (a secure context) rather than their plain-HTTP LBs.
# The OIDC issuer points at the external Keycloak (03 / 02-install-kagent.sh);
# nothing to reconfigure here.
#
# TWO distinct UIs — the agentregistry catalog is NOT a page in the management
# (Solo Enterprise) UI at this version:
#   * Registry catalog UI — the agentregistry-enterprise-server's OWN SPA
#     (agents, MCP servers, skills, prompts, runtimes, deployments). This is the
#     catalog browser. Port :12121, path '/'.
#   * Management UI — the shared Solo Enterprise UI (`solo-enterprise-ui`). In
#     this demo it serves the kagent product (/ke): the agents kagent
#     actually RUNS. The 0.4.x management frontend has no agentregistry (/are)
#     page, so the catalog lives only in the registry's own UI above.
#
# Usage: ui-login.sh        (Ctrl-C to stop the port-forwards)
#
# Author: Brian Jimerson

set -eu
set -o pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/kube-context.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/kube-context.sh"

REG_PORT=12121   # agentregistry catalog UI
UI_PORT=4000     # management (kagent) UI

require_env() {
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then
      echo -e "${RED}ERROR: $v is not set. Source your .envrc first.${NC}" >&2; exit 1
    fi
  done
}

solo_kube_init
require_env CLUSTER_CONTEXT KAGENT_NAMESPACE AGENTREGISTRY_NAMESPACE

kc() { command kubectl --context "${CLUSTER_CONTEXT}" "$@"; }

PIDS=()
# shellcheck disable=SC2154  # 'p' is the loop variable inside the quoted trap
trap 'for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done' EXIT

# Registry catalog UI (the star of this demo).
echo -e "${BLUE}Port-forwarding the agentregistry catalog UI to localhost:${REG_PORT}...${NC}"
kc -n "${AGENTREGISTRY_NAMESPACE}" port-forward svc/agentregistry-enterprise-server \
  "${REG_PORT}:12121" >/tmp/enterprise-ar-registry-pf.log 2>&1 &
PIDS+=($!)

# Management UI (kagent) — best-effort; only if the service exists (co-install
# may have moved/removed it). Non-fatal so the catalog UI still comes up.
MGMT_OK=0
if kc -n "${KAGENT_NAMESPACE}" get svc solo-enterprise-ui >/dev/null 2>&1; then
  echo -e "${BLUE}Port-forwarding the management (kagent) UI to localhost:${UI_PORT}...${NC}"
  kc -n "${KAGENT_NAMESPACE}" port-forward svc/solo-enterprise-ui \
    "${UI_PORT}:80" >/tmp/enterprise-ar-ui-pf.log 2>&1 &
  PIDS+=($!)
  MGMT_OK=1
else
  echo -e "${YELLOW}Note: management UI (solo-enterprise-ui) not found in ${KAGENT_NAMESPACE}; skipping.${NC}"
fi
sleep 4

# Fail loudly if the registry port-forward died instead of silently waiting.
if ! kill -0 "${PIDS[0]}" 2>/dev/null; then
  echo -e "${RED}ERROR: the registry UI port-forward exited immediately. Last lines of the log:${NC}" >&2
  tail -5 /tmp/enterprise-ar-registry-pf.log >&2 2>/dev/null || true
  exit 1
fi

echo ""
echo -e "${GREEN}Registry catalog UI:${NC} http://localhost:${REG_PORT}/    agents, MCP servers, skills, prompts, runtimes"
if [ "${MGMT_OK}" = "1" ]; then
  echo -e "${GREEN}Management (kagent) UI:${NC} http://localhost:${UI_PORT}/   deployed agents (opens on kagent /ke)"
fi
echo -e "${CYAN}Log in via ${KEYCLOAK_EXTERNAL_URL:-your Keycloak} (realm '${KEYCLOAK_REALM:-solo}') as one of:${NC}"
echo -e "  ${DEMO_USER_ADMIN:-admin-user}  (password: DEMO_USER_ADMIN_PASSWORD in .envrc)   (group=admins  → superuser)"
echo -e "  ${DEMO_USER_WRITER:-writer-user} (password: DEMO_USER_WRITER_PASSWORD in .envrc)  (group=writers)"
echo -e "  ${DEMO_USER_READER:-reader-user} (password: DEMO_USER_READER_PASSWORD in .envrc)  (group=readers)"
echo ""
echo -e "${BLUE}Port-forward(s) running. Press Ctrl-C to stop.${NC}"
wait
