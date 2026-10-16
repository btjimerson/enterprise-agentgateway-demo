#!/bin/bash

# Installs the MCP multiplexing + A2A demo workloads and their routes.
#
# Deploys:
#   - mcp-server-everything (time/weather/math tools)
#   - mcp-tools-extra        (2nd mcp-server-everything instance for multiplexing)
#   - a2a-agent             (Solo sample A2A echo agent)
#   - AgentgatewayBackend federating both MCP servers
#   - HTTPRoutes for /mcp and /a2a on the data-plane proxy
#
# Usage: 07-install-mcp-agents.sh [--cleanup]
#
# Author: Brian Jimerson

set -u

BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Kube-context confirmation + pinning.
# shellcheck source=../common/kube-context.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/kube-context.sh"

usage() { echo -e "Usage: $0 [--cleanup]"; exit 1; }

require_env() {
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then
      echo -e "${RED}ERROR: $v is not set. Source your .envrc first.${NC}" >&2
      exit 1
    fi
  done
}

cleanup() {
  echo ""
  echo -e "${RED}Removing MCP + A2A resources...${NC}"
  if [[ -t 0 ]]; then
    read -p "Are you sure? (y/n): " -r
    case "$REPLY" in
      [Yy]) ;;
      *) echo "Cleanup canceled."; exit 0 ;;
    esac
  fi
  for f in httproute-a2a.yaml httproute-mcp.yaml referencegrant-a2a.yaml \
           agentgatewaybackend-mcp.yaml \
           a2a-agent.yaml mcp-tools-extra.yaml mcp-everything.yaml; do
    kubectl --context "${CLUSTER_CONTEXT}" delete \
      -f "${SCRIPT_DIR}/manifests/${f}" --ignore-not-found 2>/dev/null || true
  done
  echo -e "${GREEN}Cleanup complete.${NC}"
  exit 0
}

case "${1:-}" in
  --cleanup) MODE=cleanup ;;
  -h|--help) usage ;;
  "")        MODE=install ;;
  *)         usage ;;
esac

solo_kube_init

require_env CLUSTER_CONTEXT AGENTGATEWAY_NAMESPACE DEMO_APPS_NAMESPACE

[ "$MODE" = "cleanup" ] && cleanup

echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Installing MCP servers + A2A agent${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"

kubectl --context "${CLUSTER_CONTEXT}" create namespace "${DEMO_APPS_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl --context "${CLUSTER_CONTEXT}" apply -f -

echo -e "${BLUE}Deploying mcp-server-everything...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/mcp-everything.yaml"

echo -e "${BLUE}Deploying mcp-tools-extra...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/mcp-tools-extra.yaml"

echo -e "${BLUE}Deploying a2a-agent...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/a2a-agent.yaml"

for d in mcp-server-everything mcp-tools-extra a2a-agent; do
  kubectl --context "${CLUSTER_CONTEXT}" -n "${DEMO_APPS_NAMESPACE}" \
    rollout status deploy/${d} --timeout=300s || true
done

echo -e "${BLUE}Applying mcp-federated AgentgatewayBackend...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/agentgatewaybackend-mcp.yaml"

echo -e "${BLUE}Applying ReferenceGrant (agentgateway-system HTTPRoute → a2a-agent Service)...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/referencegrant-a2a.yaml"

echo -e "${BLUE}Applying /mcp and /a2a HTTPRoutes...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/httproute-mcp.yaml"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/httproute-a2a.yaml"

echo ""
echo -e "${GREEN}MCP + A2A workloads installed.${NC}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${DEMO_APPS_NAMESPACE}" get pods,svc
