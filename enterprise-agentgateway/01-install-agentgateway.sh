#!/bin/bash

# Installs Solo Enterprise for Agentgateway (control plane + data-plane Gateway)
# into an existing Kubernetes cluster.
#
# Usage: 01-install-agentgateway.sh [--cleanup]
#
# Arguments:
#   --cleanup  Uninstall agentgateway CRDs + control plane + Gateway API CRDs
#   -h         Show usage
#
# Required env vars (see .envrc.sample):
#   AGENTGATEWAY_LICENSE_KEY, AGENTGATEWAY_VERSION, AGENTGATEWAY_NAMESPACE,
#   GATEWAY_API_VERSION, AGENTGATEWAY_CONTROLLER_REPLICAS, CLUSTER_CONTEXT
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
  echo -e "  --cleanup  Uninstall control plane + CRDs"
  echo -e "  -h         Show usage"
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

# Solo Enterprise products (agentgateway + kgateway) ship the same CRDs
# under these shared API groups. Whichever product installs first
# registers itself as the Helm owner via `meta.helm.sh/release-*`
# annotations; subsequent installs fail with "exists and cannot be
# imported". Transfer ownership to the current target release so
# `helm upgrade -i` on the CRDs chart succeeds.
#
# Args: <target-release-name> <target-namespace>
transfer_shared_crd_ownership() {
  local target_release="$1"
  local target_namespace="$2"
  local shared_groups=(extauth.solo.io ratelimit.solo.io)
  local transferred=0
  for group in "${shared_groups[@]}"; do
    for crd in $(kubectl --context "${CLUSTER_CONTEXT}" get crd -o name 2>/dev/null \
                  | grep "\.${group}$" \
                  | sed 's|^customresourcedefinition.apiextensions.k8s.io/||'); do
      local current_release
      current_release=$(kubectl --context "${CLUSTER_CONTEXT}" get crd "$crd" \
        -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null)
      if [ -n "$current_release" ] && [ "$current_release" != "$target_release" ]; then
        echo -e "${BLUE}  transferring CRD ${crd}: '${current_release}' → '${target_release}'${NC}"
        kubectl --context "${CLUSTER_CONTEXT}" annotate crd "$crd" \
          "meta.helm.sh/release-name=${target_release}" \
          "meta.helm.sh/release-namespace=${target_namespace}" \
          --overwrite >/dev/null
        transferred=$((transferred + 1))
      fi
    done
  done
  if [ "$transferred" -gt 0 ]; then
    echo -e "${BLUE}Transferred ownership of ${transferred} shared CRD(s) to ${target_release}.${NC}"
  fi
}

cleanup() {
  echo ""
  echo -e "${RED}────────────────────────────────────────────────────────────${NC}"
  echo -e "${RED}  Uninstalling Enterprise Agentgateway${NC}"
  echo -e "${RED}────────────────────────────────────────────────────────────${NC}"
  if [[ -t 0 ]]; then
    read -p "Are you sure? (y/n): " -r
    case "$REPLY" in
      [Yy]) ;;
      *) echo "Cleanup canceled."; exit 0 ;;
    esac
  fi

  echo -e "${RED}Deleting healthz Service...${NC}"
  kubectl --context "${CLUSTER_CONTEXT}" delete -f "${SCRIPT_DIR}/manifests/healthz-service.yaml" \
    --ignore-not-found 2>/dev/null || true

  echo -e "${RED}Deleting Keycloak JWKS proxy...${NC}"
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" delete \
    deploy/keycloak-jwks-proxy svc/keycloak-jwks-proxy cm/keycloak-jwks-proxy \
    --ignore-not-found 2>/dev/null || true

  echo -e "${RED}Deleting data-plane Gateway...${NC}"
  kubectl --context "${CLUSTER_CONTEXT}" delete -f "${SCRIPT_DIR}/manifests/gateway.yaml" \
    --ignore-not-found 2>/dev/null || true

  echo -e "${RED}Deleting model cost catalog and Gateway parameters...${NC}"
  kubectl --context "${CLUSTER_CONTEXT}" delete -f "${SCRIPT_DIR}/manifests/model-costs.yaml" \
    --ignore-not-found 2>/dev/null || true

  echo -e "${RED}Uninstalling enterprise-agentgateway control plane...${NC}"
  helm uninstall enterprise-agentgateway -n "${AGENTGATEWAY_NAMESPACE}" \
    --kube-context "${CLUSTER_CONTEXT}" 2>/dev/null || true

  echo -e "${RED}Uninstalling enterprise-agentgateway CRDs...${NC}"
  helm uninstall enterprise-agentgateway-crds -n "${AGENTGATEWAY_NAMESPACE}" \
    --kube-context "${CLUSTER_CONTEXT}" 2>/dev/null || true

  echo -e "${RED}Removing agentgateway CRDs...${NC}"
  kubectl --context "${CLUSTER_CONTEXT}" get crd -o name 2>/dev/null \
    | grep -E "agentgateway|enterpriseagentgateway|ratelimit.solo.io|extauth.solo.io" \
    | xargs -r kubectl --context "${CLUSTER_CONTEXT}" delete 2>/dev/null || true

  echo -e "${RED}Removing Gateway API CRDs...${NC}"
  kubectl --context "${CLUSTER_CONTEXT}" delete \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
    --ignore-not-found 2>/dev/null || true

  echo -e "${RED}Deleting namespace ${AGENTGATEWAY_NAMESPACE}...${NC}"
  kubectl --context "${CLUSTER_CONTEXT}" delete namespace "${AGENTGATEWAY_NAMESPACE}" \
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

require_env AGENTGATEWAY_LICENSE_KEY AGENTGATEWAY_VERSION \
            AGENTGATEWAY_NAMESPACE GATEWAY_API_VERSION \
            AGENTGATEWAY_CONTROLLER_REPLICAS CLUSTER_CONTEXT \
            KEYCLOAK_EXTERNAL_HOST

[ "$MODE" = "cleanup" ] && cleanup

echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Installing Enterprise Agentgateway ${AGENTGATEWAY_VERSION}${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"

echo -e "${BLUE}Installing Kubernetes Gateway API CRDs (${GATEWAY_API_VERSION})...${NC}"
kubectl apply --context "${CLUSTER_CONTEXT}" \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo -e "${BLUE}Checking for shared-CRD ownership conflicts with other Solo products...${NC}"
transfer_shared_crd_ownership "enterprise-agentgateway-crds" "${AGENTGATEWAY_NAMESPACE}"

echo -e "${BLUE}Installing Enterprise Agentgateway CRDs...${NC}"
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace \
  --namespace "${AGENTGATEWAY_NAMESPACE}" \
  --version "${AGENTGATEWAY_VERSION}" \
  --kube-context "${CLUSTER_CONTEXT}"

echo -e "${BLUE}Installing Enterprise Agentgateway control plane (replicas=${AGENTGATEWAY_CONTROLLER_REPLICAS})...${NC}"
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  -n "${AGENTGATEWAY_NAMESPACE}" \
  --version "${AGENTGATEWAY_VERSION}" \
  --kube-context "${CLUSTER_CONTEXT}" \
  --set-string licensing.licenseKey="${AGENTGATEWAY_LICENSE_KEY}" \
  --set controller.replicaCount="${AGENTGATEWAY_CONTROLLER_REPLICAS}"

echo -e "${BLUE}Waiting for control plane rollout...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" \
  rollout status -n "${AGENTGATEWAY_NAMESPACE}" deployment/enterprise-agentgateway --timeout=300s

echo -e "${BLUE}Applying model cost catalog and Gateway parameters (agw-params)...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/model-costs.yaml"

echo -e "${BLUE}Applying data-plane Gateway (agentgateway-proxy)...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/gateway.yaml"

echo -e "${BLUE}Waiting for data-plane Gateway to be programmed...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" wait -n "${AGENTGATEWAY_NAMESPACE}" \
  gateway/agentgateway-proxy --for=condition=Programmed --timeout=180s || true

# Standalone LoadBalancer Service exposing the proxy pod's built-in
# /healthz/ready (port 15021). The controller-rendered svc/agentgateway-proxy
# only carries Gateway listener ports, so the healthz endpoint needs its own
# Service to be reachable by external load balancers.
echo -e "${BLUE}Exposing data-plane healthz (port 15021)...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f "${SCRIPT_DIR}/manifests/healthz-service.yaml"

# Keycloak JWKS proxy. The gateway's JWT policy (policy-jwt.yaml) fetches JWKS
# over PLAIN HTTP via a Service backendRef — the controller can't originate TLS
# to the external HTTPS Keycloak. This Caddy proxy bridges HTTP→HTTPS so the
# gateway can validate tokens from the external Keycloak.
echo -e "${BLUE}Installing the Keycloak JWKS proxy (HTTP→HTTPS bridge for JWT validation)...${NC}"
kubectl --context "${CLUSTER_CONTEXT}" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata: { name: keycloak-jwks-proxy, namespace: ${AGENTGATEWAY_NAMESPACE} }
data:
  Caddyfile: |
    :8080 {
      reverse_proxy https://${KEYCLOAK_EXTERNAL_HOST} {
        header_up Host ${KEYCLOAK_EXTERNAL_HOST}
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: keycloak-jwks-proxy, namespace: ${AGENTGATEWAY_NAMESPACE} }
spec:
  replicas: 1
  selector: { matchLabels: { app: keycloak-jwks-proxy } }
  template:
    metadata: { labels: { app: keycloak-jwks-proxy } }
    spec:
      containers:
        - name: caddy
          image: caddy:2
          args: ["caddy","run","--config","/etc/caddy/Caddyfile","--adapter","caddyfile"]
          ports: [{ containerPort: 8080 }]
          volumeMounts: [{ name: cfg, mountPath: /etc/caddy }]
      volumes: [{ name: cfg, configMap: { name: keycloak-jwks-proxy } }]
---
apiVersion: v1
kind: Service
metadata: { name: keycloak-jwks-proxy, namespace: ${AGENTGATEWAY_NAMESPACE} }
spec:
  selector: { app: keycloak-jwks-proxy }
  ports: [{ name: http, port: 8080, targetPort: 8080 }]
EOF
# Caddy parses its Caddyfile at STARTUP, and the Caddyfile lives in a ConfigMap
# that nothing checksums into the pod template. So when only the ConfigMap
# content changes — e.g. re-running this after correcting KEYCLOAK_EXTERNAL_HOST
# in .envrc — the Deployment spec is byte-identical, no new ReplicaSet is
# created, the pod is never recycled, and `rollout status` below returns
# "successfully rolled out" instantly. The install reports success while the old
# process keeps serving the old upstream.
#
# That cost a day: the ConfigMap and the mounted file both read the right
# host while Caddy dialed the placeholder from 11 minutes before it, so every
# JWT demo returned 401 — the gateway could not fetch JWKS, and
# jwtAuthentication.mode Strict fails closed. The loudest symptom is far from
# the cause: `jwt-auth` sits at `PartiallyValid: jwks keyset ... isn't
# available`, and the demos just print 401.
#
# Forcing the roll is the same fix 10-install-elicitation.sh already applies to
# the UI for the same reason. A checksum annotation would be more precise (it
# would roll only on a real change) but needs shasum/sha256sum/openssl, none of
# which are in this demo's prerequisites — not worth a new dependency for a
# one-replica Caddy pod that only restarts at install time.
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  rollout restart deploy/keycloak-jwks-proxy
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  rollout status deploy/keycloak-jwks-proxy --timeout=120s

echo ""
echo -e "${GREEN}Enterprise Agentgateway ${AGENTGATEWAY_VERSION} installed.${NC}"
echo -e "${GREEN}Control plane pods:${NC}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" get pods
echo ""
echo -e "${GREEN}Data-plane Gateway:${NC}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" get gateway agentgateway-proxy
