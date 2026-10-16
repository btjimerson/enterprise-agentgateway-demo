#!/bin/bash

# Platform-only teardown — removes what install-infra.sh installed, in reverse.
#
#   08-install-admin-ingress.sh --cleanup
#   05-install-eso.sh           --cleanup
#   03-install-observability.sh --cleanup
#   02-install-ui.sh            --cleanup
#   01-install-agentgateway.sh  --cleanup
#
# Does NOT touch anything installed by 06, 07, 09 or 10. If those layers are
# present this script leaves them orphaned — their backends and routes would
# survive with no control plane to program them, which looks like a broken
# cluster rather than a clean one. The pre-flight below detects that case and
# points at cleanup-all.sh instead.
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
echo -e "${RED}  PLATFORM TEARDOWN — Solo Enterprise for Agentgateway${NC}"
echo -e "${RED}  Removes admin ingress, ESO, observability, UI, control plane.${NC}"
echo -e "${RED}  Leaves backends / routes / workloads / auth wiring untouched.${NC}"
echo -e "${RED}────────────────────────────────────────────────────────────${NC}"

solo_kube_init

# Detect configuration layers that this script will not remove.
NS="${AGENTGATEWAY_NAMESPACE:-agentgateway-system}"
DEMO_NS="${DEMO_APPS_NAMESPACE:-agentgateway-demo}"
LEFTOVERS=""
if kubectl --context "${CLUSTER_CONTEXT}" -n "${NS}" get agentgatewaybackend \
     --no-headers 2>/dev/null | grep -q .; then
  LEFTOVERS="${LEFTOVERS}  - AgentgatewayBackends in ${NS} (from 06/07)\n"
fi
if kubectl --context "${CLUSTER_CONTEXT}" get namespace "${DEMO_NS}" \
     >/dev/null 2>&1; then
  LEFTOVERS="${LEFTOVERS}  - the ${DEMO_NS} namespace and its workloads (from 06/07)\n"
fi
if [ -n "${LEFTOVERS}" ]; then
  echo ""
  echo -e "${YELLOW}Configuration layers are present that this script will NOT remove:${NC}"
  printf '%b' "${LEFTOVERS}"
  echo -e "${YELLOW}Removing only the platform leaves those orphaned. Use ./cleanup-all.sh${NC}"
  echo -e "${YELLOW}for a full teardown, or run 06/07/09/10 with --cleanup first.${NC}"
fi

echo ""
read -p "Proceed with platform-only teardown? (y/n): " -r
case "$REPLY" in
  [Yy]) ;;
  *) echo "Cleanup canceled."; exit 0 ;;
esac

# Reverse order. Non-TTY stdin makes each script skip its own prompt.
for step in 08-install-admin-ingress 05-install-eso \
            03-install-observability 02-install-ui \
            01-install-agentgateway; do
  echo ""
  echo -e "${BLUE}Running ${step}.sh --cleanup${NC}"
  "${SCRIPT_DIR}/${step}.sh" --cleanup </dev/null || true
done

echo ""
echo -e "${GREEN}Platform teardown complete.${NC}"
