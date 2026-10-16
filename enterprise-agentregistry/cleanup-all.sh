#!/bin/bash

# Master cleanup — runs each installer in reverse order with --cleanup.
#
# Usage: cleanup-all.sh
#
# Author: Brian Jimerson

set -u

BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Kube-context confirmation + pinning. Confirm ONCE here; per-step
# scripts inherit the choice (SOLO_CONTEXT_CONFIRMED) and don't re-prompt.
# shellcheck source=../common/kube-context.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/kube-context.sh"

echo ""
echo -e "${RED}────────────────────────────────────────────────────────────${NC}"
echo -e "${RED}  FULL TEARDOWN — Solo Enterprise for Agentregistry demo${NC}"
echo -e "${RED}  Removes registered runtimes, arctl, registry, and kagent.${NC}"
echo -e "${RED}  (the external Keycloak is left untouched.)${NC}"
echo -e "${RED}────────────────────────────────────────────────────────────${NC}"
solo_kube_init
read -p "Are you sure? (y/n): " -r
case "$REPLY" in
  [Yy]) ;;
  *) echo "Cleanup canceled."; exit 0 ;;
esac

# Reverse order. Non-TTY stdin makes each script skip its own prompt.
for step in 05-register-runtimes 04-install-arctl \
            03-install-agentregistry 02-install-kagent; do
  echo ""
  echo -e "${BLUE}Running ${step}.sh --cleanup${NC}"
  "${SCRIPT_DIR}/${step}.sh" --cleanup </dev/null || true
done

echo ""
echo -e "${GREEN}Full cleanup complete.${NC}"
