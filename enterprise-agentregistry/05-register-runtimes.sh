#!/bin/bash

# Registers deployment Runtimes with the Enterprise Agentregistry by applying
# declarative `Runtime` resources (the v2026.6.2 replacement for the old
# `arctl provider add`). Always registers the in-cluster kagent Runtime;
# optionally registers an AWS Bedrock Runtime if the corresponding
# env vars are set (.envrc.sample documents the knobs).
#
# A Runtime is a named deployment target. demo/deploy-*.sh reference these by
# name via a Deployment's `runtimeRef`.
#
# Usage: 05-register-runtimes.sh [--cleanup]
#
# Author: Brian Jimerson

set -u

BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Kube-context confirmation + pinning.
# shellcheck source=../common/kube-context.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/kube-context.sh"

# shellcheck source=demo/_common.sh
source "${SCRIPT_DIR}/demo/_common.sh"

usage() { echo -e "Usage: $0 [--cleanup]"; exit 1; }

require_env() {
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then
      echo -e "${RED}ERROR: $v is not set. Source your .envrc first.${NC}" >&2
      exit 1
    fi
  done
}

# Region used for BOTH the registry pod's AWS_REGION env and the Bedrock
# Runtime's config.region. AgentCore discovery/deploy needs a region; the
# AWS SDK can't infer one in-cluster.
AWS_REGION="${AWS_REGION:-us-east-1}"

# The registry runs IN-CLUSTER (not on EC2), so it has no IMDS instance role.
# Bedrock calls then fail with "no EC2 IMDS role found ... request to EC2 IMDS
# failed". Give it static credentials (an IAM user with sts:AssumeRole on the
# AgentRegistryAccessRole) via a Secret + deploy env, so it can assume the role
# the AWS Runtime references. Gated on REGISTRY_AWS_ACCESS_KEY_ID +
# REGISTRY_AWS_SECRET_ACCESS_KEY;
# degrades gracefully (e.g. if you run the registry on EC2 with an instance role).
# Must run BEFORE the registry port-forward — `set env` triggers a rollout that
# would otherwise drop it.
# NOTE ON THE NAMING SPLIT. The SHELL variables are deliberately
# prefixed REGISTRY_, while the Secret keys and pod env vars below stay
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY because that is what the registry
# process reads.
#
# The prefix exists because the AWS credential chain resolves environment
# variables BEFORE a named profile. On an EKS cluster, kubeconfig authenticates
# via `aws eks get-token` with AWS_PROFILE pinned in the exec env — so a bare
# AWS_ACCESS_KEY_ID exported from .envrc silently overrode that profile, the
# plugin minted a token for the wrong IAM identity, and EVERY kubectl call failed
# with "failed to download openapi: the server has asked for the client to
# provide credentials". Do not rename these back to bare AWS_*.
ensure_registry_aws_creds() {
  if [ -z "${REGISTRY_AWS_ACCESS_KEY_ID:-}" ] || [ -z "${REGISTRY_AWS_SECRET_ACCESS_KEY:-}" ]; then
    echo -e "${YELLOW}Skipping registry AWS credentials — set REGISTRY_AWS_ACCESS_KEY_ID +${NC}"
    echo -e "${YELLOW}  REGISTRY_AWS_SECRET_ACCESS_KEY in .envrc${NC}"
    echo -e "${YELLOW}  to let the in-cluster registry assume the Bedrock role (otherwise: 'no EC2 IMDS role found').${NC}"
    return 0
  fi
  echo -e "${BLUE}Wiring AWS credentials onto the registry (Secret aws-creds + deploy env, region=${AWS_REGION})...${NC}"
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
    create secret generic aws-creds \
    --from-literal=AWS_ACCESS_KEY_ID="${REGISTRY_AWS_ACCESS_KEY_ID}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${REGISTRY_AWS_SECRET_ACCESS_KEY}" \
    --from-literal=AWS_REGION="${AWS_REGION}" \
    --dry-run=client -o yaml \
    | kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" apply -f - >/dev/null
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
    set env deploy/agentregistry-enterprise-server --from=secret/aws-creds >/dev/null
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
    rollout status deploy/agentregistry-enterprise-server --timeout=120s \
    && echo -e "${GREEN}  registry restarted with AWS credentials.${NC}"
}

cleanup() {
  echo ""
  echo -e "${RED}Deleting registered Runtimes...${NC}"
  if [ ! -x "${ARCTL}" ]; then
    echo -e "${YELLOW}arctl binary not found at ${ARCTL}; nothing to clean up.${NC}"
    exit 0
  fi
  ensure_registry_portforward
  for name in "kagent" "${AWS_RUNTIME_NAME:-aws-bedrock}" "${AZURE_FOUNDRY_RUNTIME_NAME:-foundry}"; do
    "${ARCTL}" delete runtime "${name}" 2>/dev/null \
      && echo -e "${GREEN}  deleted ${name}${NC}" \
      || echo -e "${YELLOW}  (skip ${name} — not registered or arctl not logged in)${NC}"
  done
  "${ARCTL}" delete secret microsoft-foundry-creds 2>/dev/null \
    && echo -e "${GREEN}  deleted secret microsoft-foundry-creds${NC}" || true
  # Remove the AWS creds we may have wired onto the registry deploy.
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
    set env deploy/agentregistry-enterprise-server \
    AWS_ACCESS_KEY_ID- AWS_SECRET_ACCESS_KEY- AWS_REGION- >/dev/null 2>&1 || true
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
    delete secret aws-creds --ignore-not-found >/dev/null 2>&1 || true
  exit 0
}

case "${1:-}" in
  --cleanup) MODE=cleanup ;;
  -h|--help) usage ;;
  "")        MODE=install ;;
  *)         usage ;;
esac

solo_kube_init

require_env KAGENT_NAMESPACE AGENTREGISTRY_NAMESPACE \
  KEYCLOAK_ISSUER AR_BACKEND_CLIENT_ID AR_BACKEND_SECRET

[ "$MODE" = "cleanup" ] && cleanup

require_arctl

echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
echo -e "${BLUE}  Registering deployment Runtimes${NC}"
echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"

# Inject AWS creds (+ rollout) BEFORE the port-forward — the rollout would drop it.
ensure_registry_aws_creds

ensure_registry_portforward

TELEMETRY_EP="http://agentregistry-enterprise-telemetry-collector.${AGENTREGISTRY_NAMESPACE}.svc.cluster.local:4318"

# ---- kagent Runtime (always) ----
#
# config.auth.oidc IS REQUIRED as of agentregistry 2026.8.0. Without it:
#     ✗ Runtime/kagent failed: prepare: invalid input: auth.oidc is required
#       for kagent runtimes
#
# The registry calls the kagent controller with its own client-credentials
# SERVICE token — no end-user is involved — and the Runtime now has to declare
# which credentials to mint that token with rather than having it inferred.
#
# WHY ar-backend. Solo's docs use a dedicated `agentregistry-kagent` client created
# through the Keycloak admin API with a generated secret. This demo cannot do that:
# its Keycloak is your own external server and clients are seeded only by
# `--import-realm` on a fresh database. A client added to the realm file afterward is
# therefore silently ignored on any Keycloak that already has a database, and the
# resulting secret mismatch fails as `unauthorized_client`.
#
# ar-backend is already in the realm file (../keycloak/), confidential with service accounts, and
# already carries the kagent-backend audience mapper the controller's audience check
# needs. Step 02 installs a tolerant role-mapper that grants a Groups-less service
# token global.Admin, which is what lets this token through — see the comment in
# manifests/kagent/values.yaml.
#
# If you run against a Keycloak where `agentregistry-kagent` already exists, point
# AR_KAGENT_* at it instead — but its secret is generated, so you need the value
# from whoever created it.
KAGENT_OIDC_SECRET="kagent-oidc"
echo -e "${BLUE}Storing the outbound OIDC secret (registry Secret '${KAGENT_OIDC_SECRET}')...${NC}"
arctl_apply <<EOF
apiVersion: ar.dev/v1alpha1
kind: Secret
metadata:
  name: ${KAGENT_OIDC_SECRET}
spec:
  type: Opaque
  stringData:
    clientSecret: "${AR_BACKEND_SECRET}"
EOF

echo -e "${BLUE}Registering kagent Runtime (in-cluster)...${NC}"
arctl_apply <<EOF
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata:
  name: kagent
spec:
  type: Kagent
  telemetryEndpoint: ${TELEMETRY_EP}
  config:
    kagentUrl: http://kagent-controller.${KAGENT_NAMESPACE}:8083
    namespace: ${KAGENT_NAMESPACE}
    auth:
      oidc:
        issuer: ${KEYCLOAK_ISSUER}
        clientId: ${AR_BACKEND_CLIENT_ID}
        clientSecretRef:
          name: ${KAGENT_OIDC_SECRET}
          key: clientSecret
EOF

# ---- AWS Bedrock Runtime (optional) ----
# AWS targets need a one-time CloudFormation bootstrap that establishes the
# cross-account IAM role:  arctl runtime setup bedrock-agent-core
# Then register a Runtime referencing the role ARN. Spec keys may need a
# tweak per your account — see `arctl runtime setup --help`.
if [ -n "${AWS_ACCOUNT_ID:-}" ] && [ -n "${AWS_PROVIDER_ROLE_ARN:-}" ] && [ -n "${AWS_PROVIDER_EXTERNAL_ID:-}" ]; then
  AWS_NAME="${AWS_RUNTIME_NAME:-aws-bedrock}"
  echo -e "${BLUE}Registering AWS Bedrock Runtime '${AWS_NAME}' (region=${AWS_REGION})...${NC}"
  # BedrockAgentCore requires roleArn + externalId + region. roleArn/externalId
  # come from `arctl runtime setup bedrock-agent-core` → deploy the CloudFormation
  # stack → read them from the stack Outputs (RoleArn, ExternalId). The externalId
  # is the registry's identity, baked into the role's trust policy (sts:ExternalId).
  # region scopes which AgentCore region the syncer discovers/deploys in — without
  # it the syncer returns no Unmanaged instances even with valid creds.
  arctl_apply <<EOF
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata:
  name: ${AWS_NAME}
spec:
  type: BedrockAgentCore
  telemetryEndpoint: ${TELEMETRY_EP}
  config:
    region: ${AWS_REGION}
    roleArn: ${AWS_PROVIDER_ROLE_ARN}
    externalId: ${AWS_PROVIDER_EXTERNAL_ID}
EOF
else
  echo -e "${YELLOW}Skipping AWS Bedrock Runtime — set AWS_ACCOUNT_ID + AWS_PROVIDER_ROLE_ARN + AWS_PROVIDER_EXTERNAL_ID in .envrc to include.${NC}"
  echo -e "${YELLOW}  (roleArn + externalId come from 'arctl runtime setup bedrock-agent-core' → the CloudFormation stack Outputs.)${NC}"
fi

# ---- Microsoft Foundry Runtime (optional — DISCOVERY only) ----
# Discovery-only: the registry never deploys to Foundry; it lists agents already
# running in a Foundry project and shows them as Unmanaged instances. Auth is the
# Entra client-credentials flow; the client secret is stored via the registry
# Secret API (not a literal on the Runtime) and referenced by clientSecretRef.
#
# CONFIG SHAPE CHANGED IN v2026.8.0, the same move as
# demo/p01-discover-01-foundry.sh:
#   config.tenantId             -> gone; expressed as config.auth.oidc.issuer,
#                                  https://login.microsoftonline.com/<tenant>/v2.0
#   config.clientId             -> config.auth.oidc.clientId
#   config.auth.clientSecretRef -> config.auth.oidc.clientSecretRef
# subscriptionId / resourceGroup stay directly under config.
if [ -n "${AZURE_FOUNDRY_TENANT_ID:-}" ] && [ -n "${AZURE_FOUNDRY_CLIENT_ID:-}" ] \
   && [ -n "${AZURE_FOUNDRY_CLIENT_SECRET:-}" ] && [ -n "${AZURE_FOUNDRY_PROJECT_ENDPOINT:-}" ]; then
  FOUNDRY_NAME="${AZURE_FOUNDRY_RUNTIME_NAME:-foundry}"
  FOUNDRY_SECRET="microsoft-foundry-creds"
  echo -e "${BLUE}Storing Foundry client secret (registry Secret '${FOUNDRY_SECRET}')...${NC}"
  arctl_apply <<EOF
apiVersion: ar.dev/v1alpha1
kind: Secret
metadata:
  name: ${FOUNDRY_SECRET}
spec:
  type: Opaque
  stringData:
    clientSecret: "${AZURE_FOUNDRY_CLIENT_SECRET}"
EOF
  echo -e "${BLUE}Registering Microsoft Foundry Runtime '${FOUNDRY_NAME}' (discovery-only)...${NC}"
  # Optional Azure coordinates only enrich the UI's deep-links back to Azure.
  FOUNDRY_OPT=""
  [ -n "${AZURE_FOUNDRY_SUBSCRIPTION_ID:-}" ] && FOUNDRY_OPT+=$'\n'"    subscriptionId: \"${AZURE_FOUNDRY_SUBSCRIPTION_ID}\""
  [ -n "${AZURE_FOUNDRY_RESOURCE_GROUP:-}" ]  && FOUNDRY_OPT+=$'\n'"    resourceGroup: \"${AZURE_FOUNDRY_RESOURCE_GROUP}\""
  arctl_apply <<EOF
apiVersion: ar.dev/v1alpha1
kind: Runtime
metadata:
  name: ${FOUNDRY_NAME}
spec:
  type: MicrosoftFoundry
  config:
    projectEndpoint: "${AZURE_FOUNDRY_PROJECT_ENDPOINT}"${FOUNDRY_OPT}
    auth:
      oidc:
        issuer: "https://login.microsoftonline.com/${AZURE_FOUNDRY_TENANT_ID}/v2.0"
        clientId: "${AZURE_FOUNDRY_CLIENT_ID}"
        clientSecretRef:
          name: ${FOUNDRY_SECRET}
          key: clientSecret
EOF
else
  echo -e "${YELLOW}Skipping Microsoft Foundry Runtime — set AZURE_FOUNDRY_TENANT_ID + AZURE_FOUNDRY_CLIENT_ID + AZURE_FOUNDRY_CLIENT_SECRET + AZURE_FOUNDRY_PROJECT_ENDPOINT in .envrc to include.${NC}"
  echo -e "${YELLOW}  (discovery-only — see demo/p01-discover-01-foundry.sh for the Azure-side prerequisites.)${NC}"
fi

echo ""
echo -e "${BLUE}Registered Runtimes:${NC}"
"${ARCTL}" get runtimes 2>&1 || echo -e "${YELLOW}  (list failed — is arctl logged in?)${NC}"

echo ""
echo -e "${GREEN}Runtime registration complete.${NC}"
echo -e "${GREEN}Next:${NC}  ./demo/p01-catalog-01-register-mcp.sh"
echo -e "         ./demo/p03-deploy-01-kagent-k8s.sh"
