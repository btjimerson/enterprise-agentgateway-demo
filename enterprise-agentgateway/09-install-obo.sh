#!/bin/bash

# Enables on-behalf-of (RFC 8693) token exchange on the Enterprise
# Agentgateway control plane, applies the actor ServiceAccount, and exposes
# the STS endpoint through the admin Gateway on port 7777.
#
# The token-exchange configuration:
#   - issuer:            enterprise-agentgateway.<ns>.svc.cluster.local:7777
#   - subject validator: Keycloak remote JWKS (KEYCLOAK_JWKS_URL)
#   - actor validator:   k8s (accepts ServiceAccount tokens)
#   - api validator:     k8s
#
# Usage: 09-install-obo.sh [--cleanup]
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

usage() {
  echo -e "Usage: $0 [--cleanup]"
  echo -e "  --cleanup  Disable tokenExchange + remove SA + STS route"
  exit 1
}

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
  echo -e "${RED}Disabling tokenExchange + removing OBO resources...${NC}"
  if [[ -t 0 ]]; then
    read -p "Are you sure? (y/n): " -r
    case "$REPLY" in
      [Yy]) ;;
      *) echo "Cleanup canceled."; exit 0 ;;
    esac
  fi

  kubectl --context "${CLUSTER_CONTEXT}" delete \
    -f "${SCRIPT_DIR}/manifests/admin-route-sts.yaml" --ignore-not-found 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" delete \
    -f "${SCRIPT_DIR}/manifests/agent-service-account.yaml" --ignore-not-found 2>/dev/null || true

  # Drop the sts listener from admin-proxy. Re-applying admin-gateway.yaml is
  # not a reversal — we have to remove the listener via kubectl patch.
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    patch gateway admin-proxy --type=json \
    -p='[{"op":"remove","path":"/spec/listeners/3"}]' 2>/dev/null || true

  helm upgrade -i enterprise-agentgateway \
    oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
    -n "${AGENTGATEWAY_NAMESPACE}" \
    --version "${AGENTGATEWAY_VERSION}" \
    --kube-context "${CLUSTER_CONTEXT}" \
    --reuse-values \
    --set tokenExchange.enabled=false 2>/dev/null || true

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

require_env AGENTGATEWAY_LICENSE_KEY AGENTGATEWAY_VERSION \
            AGENTGATEWAY_NAMESPACE CLUSTER_CONTEXT \
            KEYCLOAK_JWKS_URL

[ "$MODE" = "cleanup" ] && cleanup

echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Installing OBO / RFC 8693 token exchange${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"

echo -e "${BLUE}Re-applying agent gateway chart with tokenExchange.enabled=true...${NC}"
# --reuse-values keeps the license key + replica count + UI toggle from the
# earlier installs; we only flip on the tokenExchange block here.
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "${AGENTGATEWAY_NAMESPACE}" \
  --version "${AGENTGATEWAY_VERSION}" \
  --kube-context "${CLUSTER_CONTEXT}" \
  --reuse-values \
  --set tokenExchange.enabled=true \
  --set "tokenExchange.issuer=enterprise-agentgateway.${AGENTGATEWAY_NAMESPACE}.svc.cluster.local:7777" \
  --set tokenExchange.tokenExpiration=4h \
  --set tokenExchange.subjectValidator.validatorType=remote \
  --set "tokenExchange.subjectValidator.remoteConfig.url=${KEYCLOAK_JWKS_URL}" \
  --set tokenExchange.actorValidator.validatorType=k8s \
  --set tokenExchange.apiValidator.validatorType=k8s

echo -e "${BLUE}Waiting for control plane to re-roll with tokenExchange...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  rollout status deploy/enterprise-agentgateway --timeout=300s

echo -e "${BLUE}Applying agent ServiceAccount (agentgateway-demo/agent-sa)...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply \
  -f "${SCRIPT_DIR}/manifests/agent-service-account.yaml"

echo -e "${BLUE}Adding STS listener to admin-proxy + HTTPRoute...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply \
  -f "${SCRIPT_DIR}/manifests/admin-gateway.yaml"
kubectl --context "${CLUSTER_CONTEXT}" apply \
  -f "${SCRIPT_DIR}/manifests/admin-route-sts.yaml"

ADMIN_LB=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  get gateway admin-proxy \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
[ -z "${ADMIN_LB}" ] && ADMIN_LB="<pending>"

echo ""
echo -e "${GREEN}OBO token exchange installed.${NC}"
echo -e "${GREEN}STS endpoint:${NC} http://${ADMIN_LB}:7777"
echo -e "${GREEN}Actor SA:${NC}     agentgateway-demo/agent-sa"
echo ""
echo -e "${BLUE}# Paste this so demo/p05-security-03-obo.sh hits the LB directly:${NC}"
echo "export STS_URL=http://${ADMIN_LB}:7777"
