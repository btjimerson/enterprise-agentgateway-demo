#!/bin/bash

# Platform-only installer — stands up the Agentgateway PLATFORM and stops.
#
# Use this when you want a running control plane, UI, observability stack and
# admin ingress WITHOUT any of the demo's backends, routes, workloads or auth
# wiring. Useful for testing an upgrade, reproducing a customer issue against a
# clean gateway, or building your own configuration on top.
#
# Runs, in order:
#   01-install-agentgateway.sh   control plane + CRDs + data-plane Gateway
#   02-install-ui.sh             Solo Enterprise UI (management chart) + ClickHouse
#   03-install-observability.sh  Prometheus + Grafana + OTel collector + dashboards
#   05-install-eso.sh            External Secrets Operator + fake ClusterSecretStore
#   08-install-admin-ingress.sh  admin-proxy Gateway (Grafana 3000, UI 4000, STS 7777)
#
# There is no 04 — the numbering has a gap, nothing is being skipped there.
#
# DELIBERATELY NOT RUN. These apply configuration rather than platform:
#   06-install-llm-backends.sh   AgentgatewayBackends, /chat + /vllm routes, mock LLMs
#   07-install-mcp-agents.sh     MCP server + A2A agent workloads
#   09-install-obo.sh            RFC 8693 token-exchange (STS) wiring
#   10-install-elicitation.sh    URL-mode elicitation wiring
#
# CONSEQUENCE: most demo scripts will NOT work after this. They assume the
# backends and routes from 06 and the workloads from 07. Run install-all.sh for a
# demo-ready cluster, or run 06/07/09/10 individually on top of this.
#
# Usage: install-infra.sh
#
# Pair with cleanup-infra.sh, which removes the same five in reverse.
#
# Author: Brian Jimerson

set -u

BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Kube-context confirmation + pinning. Confirm ONCE here; the
# per-step scripts inherit the choice (SOLO_CONTEXT_CONFIRMED) and don't
# re-prompt.
# shellcheck source=../common/kube-context.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/kube-context.sh"

# Only the license is a hard requirement for the platform: step 01 will not
# install without it.
if [ -z "${AGENTGATEWAY_LICENSE_KEY:-}" ]; then
  echo -e "${RED}ERROR: AGENTGATEWAY_LICENSE_KEY is not set. Run 'direnv allow' in ${SCRIPT_DIR} first.${NC}" >&2
  exit 1
fi

# OPENAI_API_KEY is a warning, not an error. Step 05 uses it to hydrate the fake
# secret store, but nothing in the platform layer reads `openai-secret` — only
# the LLM backends from step 06 do. So a platform-only install without an OpenAI
# key is legitimate; it just leaves the secret empty.
if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo -e "${YELLOW}NOTE: OPENAI_API_KEY is not set. ESO will still install, but"
  echo -e "      'openai-secret' will be empty. That only matters if you later run"
  echo -e "      06-install-llm-backends.sh.${NC}"
fi

echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Installing the Agentgateway PLATFORM only${NC}"
echo -e "${BLUE}  (01, 02, 03, 05, 08 — no backends, routes, workloads or auth)${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"

solo_kube_init

STEPS=(
  "01-install-agentgateway.sh"
  "02-install-ui.sh"
  "03-install-observability.sh"
  "05-install-eso.sh"
  "08-install-admin-ingress.sh"
)

START=$(date +%s)
for step in "${STEPS[@]}"; do
  echo ""
  echo -e "${BLUE}▶ Running ${step}${NC}"
  if ! "${SCRIPT_DIR}/${step}"; then
    echo ""
    echo -e "${RED}✗ ${step} failed. Aborting.${NC}"
    exit 1
  fi
done
END=$(date +%s)

echo ""
echo -e "${GREEN}────────────────────────────────────────────────────────────${NC}"
echo -e "${GREEN}  Platform install complete in $((END - START))s.${NC}"
echo -e "${GREEN}────────────────────────────────────────────────────────────${NC}"
echo ""
echo -e "${GREEN}Verify:${NC}"
echo -e "  kubectl -n ${AGENTGATEWAY_NAMESPACE:-agentgateway-system} get pods"
echo -e "  kubectl -n ${AGENTGATEWAY_NAMESPACE:-agentgateway-system} get gateway"
echo ""
echo -e "${YELLOW}No LLM backends, routes, MCP workloads or auth wiring are installed,${NC}"
echo -e "${YELLOW}so the demo scripts under demo/ will not work yet. To add layers:${NC}"
echo -e "  ./06-install-llm-backends.sh    # backends + /chat + /vllm routes + mock LLMs"
echo -e "  ./07-install-mcp-agents.sh      # MCP + A2A workloads"
echo -e "  ./09-install-obo.sh             # token exchange / STS"
echo -e "  ./10-install-elicitation.sh     # elicitation wiring"
echo ""
echo -e "${GREEN}Teardown:${NC} ./cleanup-infra.sh"
