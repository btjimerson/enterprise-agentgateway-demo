#!/bin/bash

# Platform-only teardown — removes what install-infra.sh installed, in reverse.
#
#   04-install-arctl.sh          --cleanup
#   03-install-agentregistry.sh  --cleanup
#   02-install-kagent.sh         --cleanup
#
# Does NOT touch Runtimes registered by 05 or catalog content from
# seed-registry-data.sh. Those live in the registry's own database rather than in
# Kubernetes, so tearing down the platform underneath them destroys the database
# and takes them with it — but without running their cleanup first, any external
# state they created (for example an AWS-side registration) is left behind. The
# pre-flight below detects registered Runtimes and points at cleanup-all.sh.
#
# Usage: cleanup-infra.sh
#
# Author: Brian Jimerson

set -u

BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common/kube-context.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/kube-context.sh"

echo ""
echo -e "${RED}────────────────────────────────────────────────────────────${NC}"
echo -e "${RED}  PLATFORM TEARDOWN — Solo Enterprise for Agentregistry${NC}"
echo -e "${RED}  Removes arctl, the registry server, and kagent.${NC}"
echo -e "${RED}  Does not run cleanup for registered Runtimes or catalog data.${NC}"
echo -e "${RED}────────────────────────────────────────────────────────────${NC}"

solo_kube_init

# Detect registered Runtimes, which this script does not clean up explicitly.
# arctl may not be on PATH (04 writes bin/arctl-path.env), so this is
# best-effort and stays quiet when the CLI is unavailable.
ARCTL_BIN=""
if command -v arctl >/dev/null 2>&1; then ARCTL_BIN=arctl
elif [ -x "${HOME}/.arctl/bin/arctl" ]; then ARCTL_BIN="${HOME}/.arctl/bin/arctl"
fi
if [ -n "${ARCTL_BIN}" ]; then
  RUNTIMES=$("${ARCTL_BIN}" get runtime --no-headers 2>/dev/null | awk '{print $1}' | paste -sd' ' -)
  if [ -n "${RUNTIMES:-}" ]; then
    echo ""
    echo -e "${YELLOW}Runtimes are still registered: ${RUNTIMES}${NC}"
    echo -e "${YELLOW}This teardown destroys the registry database, which removes them, but${NC}"
    echo -e "${YELLOW}does not run 05-register-runtimes.sh --cleanup first — so any external${NC}"
    echo -e "${YELLOW}state (e.g. an AWS-side registration) is left as-is. Use ./cleanup-all.sh${NC}"
    echo -e "${YELLOW}for a full teardown.${NC}"
  fi
fi

echo ""
read -p "Proceed with platform-only teardown? (y/n): " -r
case "$REPLY" in
  [Yy]) ;;
  *) echo "Cleanup canceled."; exit 0 ;;
esac

# Reverse order. Non-TTY stdin makes each script skip its own prompt.
for step in 04-install-arctl 03-install-agentregistry 02-install-kagent; do
  echo ""
  echo -e "${BLUE}Running ${step}.sh --cleanup${NC}"
  "${SCRIPT_DIR}/${step}.sh" --cleanup </dev/null || true
done

echo ""
echo -e "${GREEN}Platform teardown complete.${NC}"
