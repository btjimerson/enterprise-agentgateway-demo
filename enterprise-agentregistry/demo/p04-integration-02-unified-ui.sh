#!/bin/bash
# Pillar 4 · Integration — Case 2: Solo Enterprise UI ↔ agentregistry.
#
# What it shows
#   The "single pane of glass" story: the Solo Enterprise management UI
#   (solo-enterprise-ui in the kagent namespace) alongside the
#   agentregistry catalog. 03-install-agentregistry.sh wires the UI's
#   AGENTREGISTRY_API_ENDPOINT so the browser SPA can reach the registry.
#
#   The degree of integration depends on the management chart version.
#   This script opens both UIs and lets the presenter show what the pinned
#   chart version (KAGENT_ENT_VERSION) renders today; the registry's OWN UI
#   (p01-catalog-03) is always the complete catalog experience.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

require_cmds kubectl

trap '_cleanup_portforwards' EXIT

demo_header "Pillar 4 · Integration — Solo UI + agentregistry"

ensure_registry_portforward

demo_step "Registry's own UI (always the full catalog experience)"
echo -e "  ${BOLD}${REGISTRY_URL:-http://localhost:12121}/${NC}"
echo -e "  ${CYAN}Catalog browse, search, instances, tracing — all here.${NC}"

demo_step "Solo Enterprise management UI"
if kubectl --context "${CLUSTER_CONTEXT}" -n "${KAGENT_NAMESPACE}" \
     get deploy solo-enterprise-ui >/dev/null 2>&1; then
  AGENTREGISTRY_EP=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${KAGENT_NAMESPACE}" \
    get deploy solo-enterprise-ui -o jsonpath='{.spec.template.spec.containers[?(@.name=="ui-frontend")].env[?(@.name=="AGENTREGISTRY_API_ENDPOINT")].value}' 2>/dev/null || echo "")
  echo -e "  ${GREEN}solo-enterprise-ui is installed.${NC}"
  echo -e "  AGENTREGISTRY_API_ENDPOINT = ${AGENTREGISTRY_EP:-<unset>}"
  echo -e "  ${CYAN}Port-forward + open (the SPA lands on /age; the registry views are /are):${NC}"
  echo -e "    kubectl -n ${KAGENT_NAMESPACE} port-forward svc/solo-enterprise-ui 4000:80"
  echo -e "    ${BOLD}http://localhost:4000/are/${NC}            catalog"
  echo -e "    ${BOLD}http://localhost:4000/are/instances${NC}   live instances"
  echo -e "  ${CYAN}(or just run ../ui-login.sh)${NC}"
  echo ""
  echo -e "  ${YELLOW}The /are views call AGENTREGISTRY_API_ENDPOINT directly from the${NC}"
  echo -e "  ${YELLOW}browser. If the page loads but shows no data, that endpoint isn't${NC}"
  echo -e "  ${YELLOW}reachable from your laptop — use the registry UI above (p01-catalog-03)${NC}"
  echo -e "  ${YELLOW}and arctl for the complete catalog experience.${NC}"
else
  echo -e "${YELLOW}  solo-enterprise-ui not found — run ../02-install-kagent.sh.${NC}"
fi

prompt_continue "Walk both UIs — press Enter when done"
