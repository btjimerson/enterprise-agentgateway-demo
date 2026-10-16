#!/bin/bash

# Master installer — runs 01 through 10 in order, stopping on the first failure.
# Installs everything the demos need, but applies no demo POLICIES (each demo
# script owns its own policy lifecycle). For the platform alone — control plane,
# UI, observability, ESO, admin ingress, and nothing else — use install-infra.sh. (10-install-elicitation.sh skips itself
# gracefully when GITHUB_CLIENT_ID/SECRET aren't set, so it never blocks a
# base install.)
#
# No demo policies are applied by install. Each demo script under `demo/`
# owns its own policy lifecycle (show → apply → test → revert-on-exit),
# keeping the install and the demos independent.
#
# Usage: install-all.sh
#
# Pair with cleanup-all.sh (which runs the same scripts in reverse with
# --cleanup).
#
# Author: Brian Jimerson

set -u

BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Kube-context confirmation + pinning. Confirm ONCE here; the
# per-step scripts inherit the choice (SOLO_CONTEXT_CONFIRMED) and don't
# re-prompt.
# shellcheck source=../common/kube-context.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/kube-context.sh"

# Basic sanity check: .envrc must be loaded — the individual installers all
# require at least AGENTGATEWAY_LICENSE_KEY + OPENAI_API_KEY. Failing fast
# here is nicer than watching step 1 die after the Helm pull.
for v in AGENTGATEWAY_LICENSE_KEY OPENAI_API_KEY; do
  if [ -z "${!v:-}" ]; then
    echo -e "${RED}ERROR: $v is not set. Run 'direnv allow' in ${SCRIPT_DIR} first.${NC}" >&2
    exit 1
  fi
done

echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Installing the full Enterprise Agentgateway infrastructure${NC}"
echo -e "${BLUE}  (01 → 10 in order; stops on first failure)${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"

solo_kube_init

STEPS=(
  "01-install-agentgateway.sh"
  "02-install-ui.sh"
  "03-install-observability.sh"
  "05-install-eso.sh"
  "06-install-llm-backends.sh"
  "07-install-mcp-agents.sh"
  "08-install-admin-ingress.sh"
  "09-install-obo.sh"
  "10-install-elicitation.sh"
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
echo -e "${GREEN}  Install complete in $((END - START))s.${NC}"
echo -e "${GREEN}────────────────────────────────────────────────────────────${NC}"
echo ""
echo -e "${GREEN}Next:${NC}"
echo -e "  kubectl -n ${AGENTGATEWAY_NAMESPACE:-agentgateway-system} get pods"
echo -e "  ./demo/p02-routing-01-happy-path.sh"
echo -e "  ./demo/p05-security-01-jwt.sh"
echo -e "  ./demo/p07-observability-01-grafana.sh"
echo ""
echo -e "${GREEN}See README.md for the demo scripts under demo/.${NC}"
