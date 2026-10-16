#!/bin/bash

# Installs the External Secrets Operator (ESO) and wires it up to materialize
# the OpenAI API key into a K8s Secret that the agentgateway AI backend reads.
#
# Uses the fake provider so the demo is portable. For a real Vault / AWS
# Secrets Manager / GCP Secret Manager hookup, swap the ClusterSecretStore.
#
# Usage: 05-install-eso.sh [--cleanup]
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
  echo -e "${RED}Uninstalling ESO + deleting external-secrets namespace...${NC}"
  if [[ -t 0 ]]; then
    read -p "Are you sure? (y/n): " -r
    case "$REPLY" in
      [Yy]) ;;
      *) echo "Cleanup canceled."; exit 0 ;;
    esac
  fi

  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    delete externalsecret openai-secret --ignore-not-found 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" \
    delete clustersecretstore fake-store --ignore-not-found 2>/dev/null || true
  helm uninstall external-secrets -n "${ESO_NAMESPACE}" \
    --kube-context "${CLUSTER_CONTEXT}" 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" delete namespace "${ESO_NAMESPACE}" \
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

require_env CLUSTER_CONTEXT ESO_NAMESPACE ESO_VERSION \
            AGENTGATEWAY_NAMESPACE OPENAI_API_KEY

[ "$MODE" = "cleanup" ] && cleanup

echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Installing External Secrets Operator ${ESO_VERSION}${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"

helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo update external-secrets >/dev/null

helm upgrade -i external-secrets external-secrets/external-secrets \
  -n "${ESO_NAMESPACE}" --create-namespace \
  --version "${ESO_VERSION}" \
  --kube-context "${CLUSTER_CONTEXT}" \
  --wait

echo -e "${BLUE}Creating ClusterSecretStore (fake provider, preloaded with OPENAI_API_KEY)...${NC}"
# Inline the store so we don't have to pipe the real API key through sed
# (which struggles with special characters like /, & and \). The reference
# manifest at manifests/eso-fake-store.yaml remains as documentation.
#
# The ESO fake provider only returns a value when BOTH `key` and `version`
# match the remoteRef. Our ExternalSecret leaves version unset, so we do
# the same here.
cat <<EOF | kubectl --context "${CLUSTER_CONTEXT}" apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: fake-store
spec:
  provider:
    fake:
      data:
        - key: openai/api-key
          value: "${OPENAI_API_KEY}"
EOF

echo -e "${BLUE}Creating ExternalSecret → openai-secret in ${AGENTGATEWAY_NAMESPACE}...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply \
  -f "${SCRIPT_DIR}/manifests/eso-openai-externalsecret.yaml"

echo -e "${BLUE}Waiting for the ExternalSecret to sync...${NC}"
for _ in $(seq 1 30); do
  if kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
       get secret openai-secret >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  get secret openai-secret >/dev/null 2>&1 \
  && echo -e "${GREEN}openai-secret materialized by ESO.${NC}" \
  || echo -e "${RED}WARNING: openai-secret not yet present. Check 'kubectl describe externalsecret openai-secret -n ${AGENTGATEWAY_NAMESPACE}'${NC}"

echo ""
echo -e "${GREEN}ESO + fake ClusterSecretStore installed.${NC}"
echo -e "${GREEN}To demo Vault instead, replace manifests/eso-fake-store.yaml with a${NC}"
echo -e "${GREEN}SecretStore of type 'vault:' pointing at your Vault cluster.${NC}"
