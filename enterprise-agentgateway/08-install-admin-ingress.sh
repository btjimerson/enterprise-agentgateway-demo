#!/bin/bash

# Stands up a second Gateway (admin-proxy) in the enterprise-agentgateway
# class with listeners for Grafana (3000), the Solo Enterprise UI (4000), and
# the STS (7777). One LoadBalancer replaces a port-forward tab per service.
#
# Deliberately does NOT expose Keycloak, and must not export KEYCLOAK_URL.
# Keycloak is an EXTERNAL server (public HTTPS, see ../keycloak/);
# demo/_common.sh derives KEYCLOAK_URL from KEYCLOAK_EXTERNAL_URL in .envrc. An
# earlier version of this script had an :18080 listener for an in-cluster
# Keycloak and printed `export KEYCLOAK_URL=http://<lb>:18080`. Pasting that
# line — which the pre-flight told you to do — overrode the correct external URL
# and every token mint failed with "route not found", because the backing
# keycloak namespace no longer exists.
#
# Usage: 08-install-admin-ingress.sh [--cleanup]
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

MANIFESTS=(
  "admin-gateway.yaml"
  "admin-route-grafana.yaml"
  "admin-route-ui.yaml"
)

usage() {
  echo -e "Usage: $0 [--cleanup]"
  echo -e "  --cleanup  Delete the admin Gateway + its admin HTTPRoutes"
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
  echo -e "${RED}Removing admin-proxy Gateway + admin HTTPRoutes...${NC}"
  if [[ -t 0 ]]; then
    read -p "Are you sure? (y/n): " -r
    case "$REPLY" in
      [Yy]) ;;
      *) echo "Cleanup canceled."; exit 0 ;;
    esac
  fi
  # Delete in reverse apply order (routes before Gateway).
  for i in 3 2 1 0; do
    kubectl --context "${CLUSTER_CONTEXT}" delete \
      -f "${SCRIPT_DIR}/manifests/${MANIFESTS[$i]}" \
      --ignore-not-found 2>/dev/null || true
  done
  echo -e "${GREEN}Cleanup complete.${NC}"
  exit 0
}

# Poll `kubectl get gateway -o jsonpath=...` until an address appears or
# we run out of attempts. Echoes the address on success, empty on timeout.
wait_for_lb() {
  local ns="$1"
  local name="$2"
  local max_attempts="${3:-60}"   # 60 × 5s = 5 minutes
  local addr=""
  for _ in $(seq 1 "${max_attempts}"); do
    addr=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${ns}" \
      get gateway "${name}" \
      -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    if [ -n "${addr}" ]; then
      echo "${addr}"
      return 0
    fi
    sleep 5
  done
  return 1
}

case "${1:-}" in
  --cleanup) MODE=cleanup ;;
  -h|--help) usage ;;
  "")        MODE=install ;;
  *)         usage ;;
esac

solo_kube_init

require_env CLUSTER_CONTEXT AGENTGATEWAY_NAMESPACE

[ "$MODE" = "cleanup" ] && cleanup

echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Installing admin ingress (Gateway + 3 HTTPRoutes)${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"

for m in "${MANIFESTS[@]}"; do
  echo -e "${BLUE}Applying ${m}...${NC}"
  kubectl --context "${CLUSTER_CONTEXT}" apply \
    -f "${SCRIPT_DIR}/manifests/${m}"
done

echo ""
echo -e "${BLUE}Waiting for admin-proxy LoadBalancer address (up to 5 min)...${NC}"
ADMIN_LB=$(wait_for_lb "${AGENTGATEWAY_NAMESPACE}" admin-proxy || true)
if [ -z "${ADMIN_LB}" ]; then
  echo -e "${RED}WARNING: admin-proxy never got a LoadBalancer address.${NC}"
  echo -e "${RED}Check 'kubectl -n ${AGENTGATEWAY_NAMESPACE} get gateway admin-proxy' and 'kubectl get svc'.${NC}"
  ADMIN_LB="<pending>"
fi

echo -e "${BLUE}Looking up main agentgateway-proxy address...${NC}"
MAIN_LB=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  get gateway agentgateway-proxy \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
[ -z "${MAIN_LB}" ] && MAIN_LB="<pending>"

echo ""
echo -e "${GREEN}────────────────────────────────────────────────────────────${NC}"
echo -e "${GREEN}  Admin ingress installed.${NC}"
echo -e "${GREEN}────────────────────────────────────────────────────────────${NC}"
echo ""
echo -e "${GREEN}Main gateway:       ${NC}http://${MAIN_LB}:8080"
echo -e "${GREEN}Grafana:            ${NC}http://${ADMIN_LB}:3000   (admin / admin)"
echo -e "${GREEN}Solo Enterprise UI: ${NC}http://${ADMIN_LB}:4000/age/"
echo -e "${GREEN}STS (OBO):          ${NC}http://${ADMIN_LB}:7777   (active after 09-install-obo.sh)"
echo ""
echo -e "${BLUE}# Paste this into your shell so demo/*.sh scripts hit the LB${NC}"
echo -e "${BLUE}# directly (skipping kubectl port-forward):${NC}"
echo ""
echo "export GATEWAY_URL=http://${MAIN_LB}:8080"
echo "export STS_URL=http://${ADMIN_LB}:7777"
