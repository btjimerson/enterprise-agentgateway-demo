#!/bin/bash

# Installs Solo Enterprise for Agentregistry (AGENTREGISTRY_VERSION) in-cluster,
# following https://docs.solo.io/agentregistry/latest/quickstart/kagent/.
#
# The chart is PUBLIC (oci://us-docker.pkg.dev/solo-public/...) and
# exposes OIDC + RBAC as first-class chart values — so this script just runs
# `helm upgrade` with the native oidc.* knobs. No image-pull secret (public
# image) and NO post-install ConfigMap/Secret patching (the old v0.0.14 hack
# is gone). The chart bundles its own Postgres, ClickHouse, and an OTel
# telemetry collector.
#
# Usage: 03-install-agentregistry.sh [--cleanup]
#
# Author: Brian Jimerson

set -eu
set -o pipefail

BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Kube-context confirmation + pinning.
# shellcheck source=../common/kube-context.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/kube-context.sh"
# Live OIDC discovery probe for KEYCLOAK_ISSUER — require_env only proves it is
# non-empty, which the .envrc.sample placeholder satisfies.
# shellcheck source=../common/keycloak-issuer.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/keycloak-issuer.sh"

# Chart fullname is "agentregistry-enterprise-*" regardless of release name.
REGISTRY_DEPLOY="agentregistry-enterprise-server"

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
  echo -e "${RED}Uninstalling Enterprise Agentregistry...${NC}"
  if [[ -t 0 ]]; then
    read -p "Are you sure? (y/n): " -r
    case "$REPLY" in
      [Yy]) ;;
      *) echo "Cleanup canceled."; exit 0 ;;
    esac
  fi
  helm uninstall "${AGENTREGISTRY_RELEASE}" \
    -n "${AGENTREGISTRY_NAMESPACE}" \
    --kube-context "${CLUSTER_CONTEXT}" 2>/dev/null || true
  # Postgres + ClickHouse are StatefulSets — their PVCs survive helm
  # uninstall. Wipe them so a re-install starts clean.
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
    delete pvc --all --ignore-not-found 2>/dev/null || true
  kubectl --context "${CLUSTER_CONTEXT}" delete namespace "${AGENTREGISTRY_NAMESPACE}" \
    --ignore-not-found 2>/dev/null || true
  echo -e "${GREEN}Agentregistry cleanup complete.${NC}"
  exit 0
}

case "${1:-}" in
  --cleanup) MODE=cleanup ;;
  -h|--help) usage ;;
  "")        MODE=install ;;
  *)         usage ;;
esac

solo_kube_init

require_env CLUSTER_CONTEXT \
            AGENTREGISTRY_NAMESPACE AGENTREGISTRY_RELEASE \
            AGENTREGISTRY_VERSION AGENTREGISTRY_CHART \
            KEYCLOAK_ISSUER AR_BACKEND_CLIENT_ID AR_BACKEND_SECRET \
            AR_PUBLIC_CLIENT_ID KEYCLOAK_ROLE_CLAIM

[ "$MODE" = "cleanup" ] && cleanup

# Fail fast on a bad/placeholder issuer. Deliberately AFTER the cleanup
# gate above — a teardown must not require Keycloak to be reachable.
solo_verify_keycloak_issuer

# OIDC points at the external Keycloak (consolidated 'solo' realm). The
# ar-backend confidential secret comes from .envrc (must match the realm import).
KC_ISSUER="${KEYCLOAK_ISSUER}"

# Service type: LoadBalancer on GKE (browser-reachable UI + API), ClusterIP on
# kind (the presenter reaches the UI/API via port-forward on 12121).
if [ "${CLUSTER_TYPE:-gke}" = "kind" ]; then
  SVC_TYPE="ClusterIP"
else
  SVC_TYPE="LoadBalancer"
fi

echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Installing Enterprise Agentregistry ${AGENTREGISTRY_VERSION}${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Service type: ${SVC_TYPE} (CLUSTER_TYPE=${CLUSTER_TYPE:-gke})${NC}"

# ---- pre-flight: dynamic volume provisioning -------------------------------
# The chart bundles Postgres and ClickHouse, both of which claim a PVC. Without
# a default StorageClass and a working CSI provisioner, those PVCs sit Pending,
# Postgres never starts, and the failure surfaces much later as
#   "database migration failed ... dial tcp <ip>:5432: connect: connection refused"
# which reads like a network problem and sends you looking in the wrong place.
# This was a real dead end on a fresh EKS cluster with no EBS CSI driver.
echo ""
echo -e "${BLUE}Pre-flight: checking for dynamic volume provisioning...${NC}"
DEFAULT_SC="$(kubectl --context "${CLUSTER_CONTEXT}" get storageclass \
  -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
  2>/dev/null | head -1)"

if [ -z "${DEFAULT_SC}" ]; then
  echo -e "${RED}  No default StorageClass on this cluster.${NC}" >&2
  echo "" >&2
  echo "  The registry chart bundles Postgres + ClickHouse; both need a PVC." >&2
  echo "  Without dynamic provisioning they stay Pending and the install fails" >&2
  echo "  later with a misleading 'connection refused' from the migration job." >&2
  echo "" >&2
  echo "  Available StorageClasses:" >&2
  kubectl --context "${CLUSTER_CONTEXT}" get storageclass --no-headers 2>/dev/null \
    | sed 's/^/    /' >&2 || echo "    (none)" >&2
  echo "" >&2
  echo "  On EKS this usually means the EBS CSI driver add-on is missing:" >&2
  echo "    aws eks create-addon --cluster-name <cluster> --addon-name aws-ebs-csi-driver" >&2
  echo "  then mark a StorageClass default:" >&2
  echo "    kubectl annotate sc gp2 storageclass.kubernetes.io/is-default-class=true" >&2
  exit 1
fi
echo -e "${GREEN}  default StorageClass: ${DEFAULT_SC}${NC}"

# A default StorageClass can exist while its provisioner is absent or broken —
# exactly the EKS case. Bind a tiny throwaway PVC to prove it actually works.
# Deliberately the `default` namespace: ${AGENTREGISTRY_NAMESPACE} does not
# exist yet, helm creates it with --create-namespace below. Applying into a
# missing namespace would fail and be misread as a broken provisioner.
PREFLIGHT_NS="default"
PREFLIGHT_PVC="agentregistry-preflight-$$"
cat <<PVC | kubectl --context "${CLUSTER_CONTEXT}" -n "${PREFLIGHT_NS}" apply -f - >/dev/null 2>&1 || true
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PREFLIGHT_PVC}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
PVC
PV_OK=0
for _ in $(seq 1 20); do
  PHASE="$(kubectl --context "${CLUSTER_CONTEXT}" -n "${PREFLIGHT_NS}" \
    get pvc "${PREFLIGHT_PVC}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  # WaitForFirstConsumer is a healthy answer: the class binds late by design.
  if [ "${PHASE}" = "Bound" ]; then PV_OK=1; break; fi
  if kubectl --context "${CLUSTER_CONTEXT}" -n "${PREFLIGHT_NS}" \
       describe pvc "${PREFLIGHT_PVC}" 2>/dev/null | grep -q 'WaitForFirstConsumer'; then
    PV_OK=2; break
  fi
  sleep 3
done
kubectl --context "${CLUSTER_CONTEXT}" -n "${PREFLIGHT_NS}" \
  delete pvc "${PREFLIGHT_PVC}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

case "${PV_OK}" in
  1) echo -e "${GREEN}  test PVC bound — dynamic provisioning works${NC}" ;;
  2) echo -e "${GREEN}  StorageClass is WaitForFirstConsumer — binds on first pod, OK${NC}" ;;
  *) echo -e "${RED}  A test PVC did not bind within 60s.${NC}" >&2
     echo "  The default StorageClass '${DEFAULT_SC}' exists but nothing provisioned it." >&2
     echo "  On EKS this is the missing EBS CSI driver add-on. Check:" >&2
     echo "    kubectl --context ${CLUSTER_CONTEXT} -n kube-system get pods | grep csi" >&2
     exit 1 ;;
esac

helm upgrade --install "${AGENTREGISTRY_RELEASE}" \
  "${AGENTREGISTRY_CHART}" \
  --version "${AGENTREGISTRY_VERSION}" \
  --namespace "${AGENTREGISTRY_NAMESPACE}" --create-namespace \
  --kube-context "${CLUSTER_CONTEXT}" \
  --values "${SCRIPT_DIR}/manifests/agentregistry/values.yaml" \
  --set-string oidc.issuer="${KC_ISSUER}" \
  --set-string oidc.clientId="${AR_BACKEND_CLIENT_ID}" \
  --set-string oidc.clientSecret="${AR_BACKEND_SECRET}" \
  --set-string oidc.publicClientId="${AR_PUBLIC_CLIENT_ID}" \
  --set-string oidc.roleClaim="${KEYCLOAK_ROLE_CLAIM}" \
  --set-string oidc.superuserRole="admins" \
  --set service.type="${SVC_TYPE}" \
  --wait --timeout 5m

echo -e "${BLUE}Waiting for deployment/${REGISTRY_DEPLOY} to be available...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
  rollout status "deployment/${REGISTRY_DEPLOY}" --timeout=300s

# ---- Wire the Solo Enterprise UI to agentregistry (browser SPA) ------------
# AGENTREGISTRY_API_ENDPOINT is surfaced to the browser via /env-config.js and
# becomes the URL the UI's JS calls directly. On GKE that must be the
# LoadBalancer IP; on kind the presenter port-forwards 12121, so the browser
# hits localhost.
ARE_EP=""
if [ "${SVC_TYPE}" = "LoadBalancer" ]; then
  echo -e "${BLUE}Waiting for agentregistry LoadBalancer external IP...${NC}"
  ARE_LB_IP=""
  for _ in $(seq 1 60); do
    ARE_LB_IP=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
      get svc "${REGISTRY_DEPLOY}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    [ -n "${ARE_LB_IP}" ] && break
    sleep 5
  done
  if [ -n "${ARE_LB_IP}" ]; then
    ARE_EP="http://${ARE_LB_IP}:12121"
    echo -e "${GREEN}  agentregistry external URL: ${ARE_EP}${NC}"
  else
    echo -e "${YELLOW}  No LB IP yet — browser-side UI calls will need a port-forward.${NC}"
    ARE_EP="http://localhost:12121"
  fi
else
  ARE_EP="http://localhost:12121"
  echo -e "${BLUE}  kind: UI/API reachable via port-forward → ${ARE_EP}${NC}"
fi

if kubectl --context "${CLUSTER_CONTEXT}" -n "${KAGENT_NAMESPACE:-kagent}" \
     get deployment solo-enterprise-ui >/dev/null 2>&1; then
  echo -e "${BLUE}Wiring solo-enterprise-ui → agentregistry (${ARE_EP})...${NC}"
  kubectl --context "${CLUSTER_CONTEXT}" -n "${KAGENT_NAMESPACE:-kagent}" \
    set env deployment/solo-enterprise-ui \
    -c ui-frontend \
    "AGENTREGISTRY_API_ENDPOINT=${ARE_EP}" >/dev/null 2>&1 || \
    echo -e "${YELLOW}  (could not set AGENTREGISTRY_API_ENDPOINT — verify the container name)${NC}"
  kubectl --context "${CLUSTER_CONTEXT}" -n "${KAGENT_NAMESPACE:-kagent}" \
    rollout status deployment/solo-enterprise-ui --timeout=180s 2>/dev/null || true
else
  echo -e "${YELLOW}  solo-enterprise-ui not found — skipping UI wire-up (run ./02 first).${NC}"
fi

echo ""
echo -e "${GREEN}Enterprise Agentregistry ready.${NC}"
echo -e "${GREEN}Namespace:${NC}       ${AGENTREGISTRY_NAMESPACE}"
echo -e "${GREEN}Server Service:${NC}  ${REGISTRY_DEPLOY} (http 12121, grpc 21212, mcp 31313)"
echo -e "${GREEN}OIDC issuer:${NC}     ${KC_ISSUER}"
echo -e "${GREEN}OIDC client:${NC}     ${AR_BACKEND_CLIENT_ID} (backend), ${AR_PUBLIC_CLIENT_ID} (UI)"
echo -e "${GREEN}Role claim:${NC}      ${KEYCLOAK_ROLE_CLAIM} → superuser role 'admins'"
if [ -n "${ARE_EP}" ]; then
  echo -e "${GREEN}API/UI:${NC}          ${ARE_EP}"
fi
echo -e "${GREEN}Next:${NC}            ./04-install-arctl.sh"
