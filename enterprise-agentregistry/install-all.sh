#!/bin/bash

# Master installer — runs 02 through 05 in order, stopping on the first failure.
# For the platform alone — kagent, the registry server, arctl, and no registered
# Runtimes or catalog data — use install-infra.sh.
#
# No demo data is applied by install. Each demo script under `demo/`
# owns its own lifecycle (register → test → prompt_continue →
# revert-on-exit), matching the pattern in ../enterprise-agentgateway/.
#
# Pair with cleanup-all.sh (which runs the same scripts in reverse
# with --cleanup).
#
# Usage: install-all.sh
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

# Fail-fast sanity check. The agentregistry image is public, so no
# AGENTREGISTRY_LICENSE_KEY is needed. The kagent enterprise charts require
# KAGENT_LICENSE_KEY, and the controller's k8s-agent needs OPENAI_API_KEY —
# both are install-time blockers.
for v in KAGENT_LICENSE_KEY OPENAI_API_KEY; do
  if [ -z "${!v:-}" ] || [ "${!v}" = "<paste>" ]; then
    echo -e "${RED}ERROR: $v is not set. Run 'direnv allow' in ${SCRIPT_DIR} first.${NC}" >&2
    exit 1
  fi
done
# GOOGLE_API_KEY is only needed by the deploy/chat demos (the gemini agent),
# not by the install itself — warn rather than block.
if [ -z "${GOOGLE_API_KEY:-}" ] || [ "${GOOGLE_API_KEY}" = "<paste>" ]; then
  echo -e "${BLUE}NOTE: GOOGLE_API_KEY is unset — install will proceed, but p03-deploy-01/chat${NC}"
  echo -e "${BLUE}      demos need it. Set it in .envrc before running those.${NC}"
fi

echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Installing Solo Enterprise for Agentregistry (pre-GA)${NC}"
echo -e "${BLUE}  (02 → 05 in order; stops on first failure)${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"

solo_kube_init

STEPS=(
  "02-install-kagent.sh"
  "03-install-agentregistry.sh"
  "04-install-arctl.sh"
  "05-register-runtimes.sh"
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
echo -e "  kubectl -n ${AGENTREGISTRY_NAMESPACE:-agentregistry-system} get pods"
echo -e "  ./arctl.sh get runtimes      # wrapper: opens the registry port-forward + mints a fresh token per call"
echo -e "  ./demo/p01-catalog-01-register-mcp.sh    # (demos open their own forward + mint their own tokens)"
echo -e "  ./demo/p02-security-02-rbac-reader-vs-writer.sh"
echo -e "  ./demo/p03-deploy-01-kagent-k8s.sh"
echo ""
