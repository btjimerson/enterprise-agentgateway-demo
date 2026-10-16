#!/bin/bash
# Pillar 3 · Multi-Cloud Deploy — Case 1: Deploy to in-cluster kagent.
#
# What it shows
#   The registry → kagent control-plane deployment path. We scaffold +
#   build a diceagent image, make it available to the cluster (kind load
#   or registry push), publish the agent, then apply a declarative
#   Deployment whose runtimeRef points at the `kagent` Runtime (created
#   by 05-register-runtimes.sh). The registry reconciles a kagent Agent
#   CR; kagent runs the pod. Finally, chat via the UI.
#
# Steps
#   1. Scaffold + build the diceagent image (Docker required).
#   2. CLUSTER_TYPE=kind → `kind load`; gke → push to DEMO_DOCKER_REGISTRY.
#   3. `arctl apply -f agent.yaml` — publish to the catalog.
#   4. `arctl apply -f` a Deployment (targetRef Agent, runtimeRef kagent).
#   5. `kubectl get pods -n kagent | grep diceagent` — see the pod.
#   6. Chat at http://localhost:12121/are/instances/.
#   7. Cleanup: delete the Deployment + agent.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

require_arctl
require_cmds jq kubectl docker

AGENT_NAME="diceagent"
WORKDIR="$(mktemp -d -t enterprise-ar-deploy-XXXXXX)"
: "${DEMO_AGENT_MODEL_PROVIDER:=gemini}"
: "${DEMO_AGENT_MODEL_NAME:=gemini-2.5-flash}"
: "${LOCAL_IMAGE_REGISTRY:=localhost:5001}"
: "${DEMO_DOCKER_REGISTRY:=ghcr.io/${USER}}"

if [ "${CLUSTER_TYPE:-gke}" = "kind" ]; then
  IMAGE="${LOCAL_IMAGE_REGISTRY}/${AGENT_NAME}:latest"
  # kind nodes run the host architecture — don't force a platform.
  BUILD_PLATFORM="${AGENT_BUILD_PLATFORM:-}"
else
  IMAGE="${DEMO_DOCKER_REGISTRY}/${AGENT_NAME}:latest"
  # GKE node pools are linux/amd64; on an Apple Silicon host the default build is
  # arm64, which pulls as "no match for platform". Force amd64 (override via
  # AGENT_BUILD_PLATFORM for arm64 node pools).
  BUILD_PLATFORM="${AGENT_BUILD_PLATFORM:-linux/amd64}"
fi

cleanup() {
  demo_step "Cleanup — removing the Deployment + agent + workdir"
  "${ARCTL}" delete deployment "${AGENT_NAME}" 2>/dev/null || true
  "${ARCTL}" delete agent "${AGENT_NAME}" 2>/dev/null || true
  rm -rf "${WORKDIR}"
}
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 3 · Multi-Cloud Deploy — kagent (in-cluster)"

ensure_registry_portforward

if [ -z "${GOOGLE_API_KEY:-}" ] || [ "${GOOGLE_API_KEY}" = "<paste>" ]; then
  echo -e "${RED}GOOGLE_API_KEY is not set — the ${DEMO_AGENT_MODEL_NAME} agent needs it to run.${NC}" >&2
  echo -e "${RED}Set it in .envrc and re-run.${NC}" >&2
  exit 1
fi

demo_step "Confirm the kagent Runtime is registered"
echo "  arctl get runtimes"
"${ARCTL}" get runtimes 2>&1 | grep -iE 'kagent|NAME' \
  || echo -e "${YELLOW}  (no kagent Runtime — run ../05-register-runtimes.sh first)${NC}"

demo_step "Scaffold + build the agent image"
echo "  arctl init agent ${AGENT_NAME} --framework adk --language python ..."
"${ARCTL}" init agent "${AGENT_NAME}" \
  --framework adk --language python \
  --model-provider "${DEMO_AGENT_MODEL_PROVIDER}" \
  --model-name "${DEMO_AGENT_MODEL_NAME}" \
  --output-dir "${WORKDIR}"
AGENT_YAML=$(find "${WORKDIR}" -name agent.yaml -type f 2>/dev/null | head -1)
AGENT_DIR=$(dirname "${AGENT_YAML}")

# The scaffold hardcodes spec.source.image=localhost:5001/diceagent:latest (the
# kind local-registry convention). Point it at the image we actually build +
# push so the published catalog entry — and the kagent Deployment it drives —
# pull a cluster-reachable image. Without this, a gke node tries to pull
# localhost:5001 and ImagePullBackOffs (the agent pod never serves :8080, and
# the UI chat fails with "connection refused" to the agent).
if command -v yq >/dev/null 2>&1; then
  yq -i ".spec.source.image = \"${IMAGE}\"" "${AGENT_YAML}"
else
  sed -i.bak -E "s|^([[:space:]]*image:[[:space:]]*).*|\1${IMAGE}|" "${AGENT_YAML}" && rm -f "${AGENT_YAML}.bak"
fi
echo -e "${CYAN}  spec.source.image → ${IMAGE}${NC}"

echo "  arctl build ${AGENT_DIR} --image ${IMAGE}${BUILD_PLATFORM:+ --platform ${BUILD_PLATFORM}}"
prompt_continue "Build the image"
"${ARCTL}" build "${AGENT_DIR}" --image "${IMAGE}" ${BUILD_PLATFORM:+--platform "${BUILD_PLATFORM}"} \
  || { echo -e "${RED}ERROR: image build failed (Docker running? build-network DNS? deps?). Fix and re-run.${NC}" >&2; exit 1; }

demo_step "Make the image available to the cluster"
if [ "${CLUSTER_TYPE:-gke}" = "kind" ]; then
  KIND_CLUSTER="${KIND_CLUSTER_NAME:-$(kubectl config current-context | sed 's/^kind-//')}"
  echo "  kind load docker-image ${IMAGE} --name ${KIND_CLUSTER}"
  kind load docker-image "${IMAGE}" --name "${KIND_CLUSTER}"
else
  echo "  docker push ${IMAGE}"
  docker push "${IMAGE}" \
    || { echo -e "${RED}ERROR: docker push to ${IMAGE} failed. 'docker login ghcr.io -u <gh-user>' (PAT with write:packages), and set DEMO_DOCKER_REGISTRY to YOUR GitHub namespace or a pullable registry.${NC}" >&2; exit 1; }
  echo -e "${CYAN}  Note: ${IMAGE} must be PULLABLE by the cluster nodes — a PUBLIC ghcr${NC}"
  echo -e "${CYAN}  package, or a GCP Artifact Registry in the cluster's project (set${NC}"
  echo -e "${CYAN}  DEMO_DOCKER_REGISTRY accordingly). Otherwise the pod ImagePullBackOffs.${NC}"
fi

demo_step "Publish the agent to the catalog"
echo "  arctl apply -f ${AGENT_YAML}"
"${ARCTL}" apply -f "${AGENT_YAML}"
"${ARCTL}" get agents

demo_step "Deploy to the kagent Runtime (declarative Deployment)"
cat <<EOF
  arctl apply -f - <<YAML
  apiVersion: ar.dev/v1alpha1
  kind: Deployment
  metadata:
    name: ${AGENT_NAME}
  spec:
    targetRef: { kind: Agent, name: ${AGENT_NAME}, tag: "latest" }
    runtimeRef: { kind: Runtime, name: kagent }
    env: { GOOGLE_API_KEY: "***" }
  YAML
EOF
prompt_continue "Apply the Deployment"
arctl_apply <<EOF
apiVersion: ar.dev/v1alpha1
kind: Deployment
metadata:
  name: ${AGENT_NAME}
spec:
  targetRef:
    kind: Agent
    name: ${AGENT_NAME}
    tag: "latest"
  runtimeRef:
    kind: Runtime
    name: kagent
  env:
    GOOGLE_API_KEY: "${GOOGLE_API_KEY}"
EOF

demo_step "Watch the agent pod come up in the kagent namespace"
echo "  kubectl -n ${KAGENT_NAMESPACE} get pods | grep ${AGENT_NAME}"
for _ in $(seq 1 24); do
  POD_LINE=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${KAGENT_NAMESPACE}" \
    get pods 2>/dev/null | grep "${AGENT_NAME}" || true)
  [ -n "${POD_LINE}" ] && { echo "  ${POD_LINE}"; break; }
  sleep 5
done
echo ""
"${ARCTL}" get deployments 2>&1 || true

demo_step "Chat with the agent"
echo -e "${CYAN}  Open ${REGISTRY_URL:-http://localhost:12121}/are/instances/ → ${AGENT_NAME} → Open Chat${NC}"
echo -e "${CYAN}  Try: \"roll 3d6\".  Traces: ${REGISTRY_URL:-http://localhost:12121}/are/tracing${NC}"

prompt_continue "Demo complete — press Enter to clean up"
