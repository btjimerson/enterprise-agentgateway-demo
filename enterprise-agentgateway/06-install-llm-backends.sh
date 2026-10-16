#!/bin/bash

# Installs the LLM backends for the demo:
#   - Mock LLM Deployment/Service (failover target)
#   - AgentgatewayBackend for OpenAI (primary)
#   - AgentgatewayBackend for mock (failover)
#   - AgentgatewayBackend with two priority groups (what the /chat route uses)
#   - HTTPRoute exposing /chat on the data-plane Gateway
#
# Usage: 06-install-llm-backends.sh [--cleanup]
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
  echo -e "${RED}Removing LLM backends + chat HTTPRoute + mock-llm...${NC}"
  if [[ -t 0 ]]; then
    read -p "Are you sure? (y/n): " -r
    case "$REPLY" in
      [Yy]) ;;
      *) echo "Cleanup canceled."; exit 0 ;;
    esac
  fi

  kubectl --context "${CLUSTER_CONTEXT}" delete \
    -f "${SCRIPT_DIR}/manifests/httproute-chat.yaml" --ignore-not-found 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" delete \
    -f "${SCRIPT_DIR}/manifests/agentgatewaybackend-multi.yaml" --ignore-not-found 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" delete \
    -f "${SCRIPT_DIR}/manifests/agentgatewaybackend-mock.yaml"  --ignore-not-found 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" delete \
    -f "${SCRIPT_DIR}/manifests/agentgatewaybackend-openai.yaml" --ignore-not-found 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" delete \
    -f "${SCRIPT_DIR}/manifests/mock-llm-deployment.yaml"       --ignore-not-found 2>/dev/null || true
  # p09 self-hosted vLLM pillar
  kubectl --context "${CLUSTER_CONTEXT}" delete \
    -f "${SCRIPT_DIR}/manifests/httproute-vllm.yaml"            --ignore-not-found 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" delete \
    -f "${SCRIPT_DIR}/manifests/agentgatewaybackend-vllm.yaml"  --ignore-not-found 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" delete \
    -f "${SCRIPT_DIR}/manifests/vllm-mock-deployment.yaml"      --ignore-not-found 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" delete namespace "${DEMO_APPS_NAMESPACE}" \
    --ignore-not-found 2>/dev/null || true
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
echo -e "${BLUE}  Installing LLM backends + /chat route${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"

kubectl --context "${CLUSTER_CONTEXT}" create namespace "${DEMO_APPS_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl --context "${CLUSTER_CONTEXT}" apply -f -

echo -e "${BLUE}Applying mock-llm Deployment + Service...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/mock-llm-deployment.yaml"
kubectl --context "${CLUSTER_CONTEXT}" -n "${DEMO_APPS_NAMESPACE}" \
  rollout status deploy/mock-llm --timeout=180s

# --- p09 self-hosted vLLM pillar -------------------------------------------
# Two OpenAI-compatible stand-ins for self-hosted vLLM servers, plus their
# backends and the shared /vllm route. Deliberately installed here rather than by
# the demo scripts: the p09 acts apply only POLICY, so each one shows a clean
# before/after without waiting on pod startup mid-demo.
echo -e "${BLUE}Applying mock vLLM fleets (gemma-4, llama-30)...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/vllm-mock-deployment.yaml"
for d in vllm-gemma vllm-llama; do
  kubectl --context "${CLUSTER_CONTEXT}" -n "${DEMO_APPS_NAMESPACE}" \
    rollout status "deploy/${d}" --timeout=180s
done

echo -e "${BLUE}Applying AgentgatewayBackends (openai, mock, multi)...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/agentgatewaybackend-openai.yaml"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/agentgatewaybackend-mock.yaml"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/agentgatewaybackend-multi.yaml"

echo -e "${BLUE}Applying /chat HTTPRoute...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/httproute-chat.yaml"

echo -e "${BLUE}Applying vLLM AgentgatewayBackends + /vllm route...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/agentgatewaybackend-vllm.yaml"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/httproute-vllm.yaml"

echo ""
echo -e "${GREEN}LLM backends installed.${NC}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  get agentgatewaybackend,httproute
