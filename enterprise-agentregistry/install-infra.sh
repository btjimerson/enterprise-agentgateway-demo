#!/bin/bash

# Platform-only installer — stands up the Agentregistry PLATFORM and stops.
#
# Use this when you want a running registry, kagent runtime and CLI WITHOUT any
# registered deployment targets or catalog content. Useful for testing an
# upgrade, reproducing a customer issue against a clean registry, or building
# your own configuration on top.
#
# Runs, in order:
#   02-install-kagent.sh         Solo Enterprise for kagent (controller, UI, ClickHouse)
#   03-install-agentregistry.sh  Agentregistry server + Postgres + UI wiring
#   04-install-arctl.sh          arctl CLI, wired with an OIDC bearer token
#
# There is no 01 — the numbering has a gap, nothing is being skipped there.
#
# DELIBERATELY NOT RUN. These apply configuration rather than platform:
#   05-register-runtimes.sh      Runtime resources (kagent, AWS Bedrock, Azure Foundry)
#   seed-registry-data.sh        catalog content
#
# CONSEQUENCE: the demo scripts under demo/ will NOT work after this. A Runtime
# is a named deployment target, and every deploy demo references one by name via
# a Deployment's runtimeRef — with none registered there is nothing to deploy to.
# Run install-all.sh for a demo-ready cluster, or ./05-register-runtimes.sh on
# top of this.
#
# Usage: install-infra.sh
#
# Pair with cleanup-infra.sh, which removes the same three in reverse.
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

# Step 02 will not install without the kagent license.
if [ -z "${KAGENT_LICENSE_KEY:-}" ]; then
  echo -e "${RED}ERROR: KAGENT_LICENSE_KEY is not set. Run 'direnv allow' in ${SCRIPT_DIR} first.${NC}" >&2
  exit 1
fi

echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Installing the Agentregistry PLATFORM only${NC}"
echo -e "${BLUE}  (02, 03, 04 — no runtimes registered, no catalog data)${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"

solo_kube_init

STEPS=(
  "02-install-kagent.sh"
  "03-install-agentregistry.sh"
  "04-install-arctl.sh"
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
echo -e "  kubectl -n ${AGENTREGISTRY_NAMESPACE:-agentregistry-system} get pods"
echo -e "  arctl get mcp"
echo ""
echo -e "${YELLOW}No Runtimes are registered and no catalog data is seeded, so the demo${NC}"
echo -e "${YELLOW}scripts under demo/ will not work yet. To add layers:${NC}"
echo -e "  ./05-register-runtimes.sh       # kagent (+ AWS / Azure if env is set)"
echo -e "  ./seed-registry-data.sh         # catalog content"
echo ""
echo -e "${GREEN}Teardown:${NC} ./cleanup-infra.sh"
