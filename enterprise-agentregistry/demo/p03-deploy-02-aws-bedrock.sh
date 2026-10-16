#!/bin/bash
# Pillar 3 · Multi-Cloud Deploy — Case 2: Deploy to AWS Bedrock AgentCore.
#
# ⚠️  EXPERIMENTAL — not functional end-to-end. This walks the
#     full AWS setup, but even with creds + region + an arm64 ECR image + a
#     registered Runtime, the registry's BedrockAgentCore adapter fails its
#     reconcile OPAQUELY (Deployment → "failed", no synchronous error, nothing
#     in the server logs, no CreateAgentRuntime call reaches AWS). The agent
#     image must also conform to the AgentCore container contract (arm64 + an
#     HTTP server on :8080 with /invocations + /ping), which the `arctl init`
#     ADK scaffold is NOT. Use p03-deploy-01 (kagent) for the working multi-runtime
#     story; treat this as illustrative until the adapter surfaces errors.
#
# What it shows
#   Same diceagent, different target: a Deployment whose runtimeRef points
#   at the AWS Bedrock Runtime registered by 05-register-runtimes.sh
#   (gated on AWS_ACCOUNT_ID + AWS_PROVIDER_ROLE_ARN). Gracefully skips
#   when no AWS Runtime exists — the normal baseline-demo path, since AWS
#   is opt-in via .envrc.
#
# Steps (when AWS is configured)
#   1. Confirm the AWS Runtime exists (else skip).
#   2. Scaffold + build + publish the agent (image pushed to your ECR).
#   3. `arctl apply -f` a Deployment with runtimeRef → <aws runtime>.
#   4. `arctl get deployments` for status.
#   5. Cleanup: delete the Deployment (AWS-side resources persist).
#
# AWS prerequisites (one-time, on your side — the demo does NOT automate these):
#   1. Bootstrap the IAM role:
#        arctl runtime setup bedrock-agent-core --aws-account-id <id> > cf.yaml
#        aws cloudformation deploy --template-file cf.yaml --stack-name <s> \
#          --capabilities CAPABILITY_NAMED_IAM
#      Read RoleArn + ExternalId from the stack Outputs.
#   2. Set in .envrc: AWS_ACCOUNT_ID, AWS_PROVIDER_ROLE_ARN, AWS_PROVIDER_EXTERNAL_ID.
#      INVARIANT: AWS_PROVIDER_EXTERNAL_ID must equal the role trust policy's
#      sts:ExternalId (the setup command mints a NEW random one each call, so use
#      the value your DEPLOYED role trusts, not a fresh generate):
#        aws iam get-role --role-name <role> \
#          --query 'Role.AssumeRolePolicyDocument.Statement[].Condition.StringEquals."sts:ExternalId"'
#   3. Give the REGISTRY AWS credentials. The role trusts an IAM identity in your
#      account; the registry must authenticate AS one to assume it. The pod runs
#      in-cluster (not on EC2), so with no creds the assume-role fails with
#      "no EC2 IMDS role found". Set an IAM user's keys (with sts:AssumeRole on the
#      role) in .envrc as REGISTRY_AWS_ACCESS_KEY_ID +
#      REGISTRY_AWS_SECRET_ACCESS_KEY (+ optional
#      AWS_REGION, default us-east-1). 05-register-runtimes.sh then wires them onto
#      the registry (Secret aws-creds + deploy env) and registers the Runtime with
#      config.region — no manual kubectl needed. A `helm upgrade` of the registry
#      reverts the env, so re-run 05 (or re-apply) after one.
#   4. ./05-register-runtimes.sh, then this script.
# Image push target + Deployment spec keys may also need adjusting per account.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

require_arctl
require_cmds jq

AGENT_NAME="diceagent"
AWS_RUNTIME="${AWS_RUNTIME_NAME:-aws-bedrock}"
WORKDIR="$(mktemp -d -t enterprise-ar-aws-XXXXXX)"
: "${DEMO_AGENT_MODEL_PROVIDER:=gemini}"
: "${DEMO_AGENT_MODEL_NAME:=gemini-2.5-flash}"

cleanup() {
  demo_step "Cleanup — removing the Deployment + workdir (AWS resources persist)"
  "${ARCTL}" delete deployment "${AGENT_NAME}-aws" 2>/dev/null || true
  rm -rf "${WORKDIR}"
}
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 3 · Multi-Cloud Deploy — AWS Bedrock AgentCore"

ensure_registry_portforward

demo_step "Check for a registered AWS Runtime named '${AWS_RUNTIME}'"
if ! "${ARCTL}" get runtimes 2>/dev/null | awk '{print $1}' | grep -qx "${AWS_RUNTIME}"; then
  echo -e "${YELLOW}  No AWS Runtime '${AWS_RUNTIME}' registered.${NC}"
  echo -e "${YELLOW}  This is the expected path for a baseline demo. To include AWS:${NC}"
  echo -e "${YELLOW}    1. arctl runtime setup bedrock-agent-core --aws-account-id <id>  # emits CloudFormation${NC}"
  echo -e "${YELLOW}    2. aws cloudformation deploy ...  → read RoleArn + ExternalId from the stack Outputs${NC}"
  echo -e "${YELLOW}    3. set AWS_ACCOUNT_ID + AWS_PROVIDER_ROLE_ARN + AWS_PROVIDER_EXTERNAL_ID in .envrc${NC}"
  echo -e "${YELLOW}    4. ./05-register-runtimes.sh${NC}"
  exit 0
fi
echo -e "${GREEN}  Found AWS Runtime '${AWS_RUNTIME}'.${NC}"

demo_step "Scaffold + publish the agent (image to your configured registry)"
"${ARCTL}" init agent "${AGENT_NAME}" \
  --framework adk --language python \
  --model-provider "${DEMO_AGENT_MODEL_PROVIDER}" \
  --model-name "${DEMO_AGENT_MODEL_NAME}" \
  --output-dir "${WORKDIR}" >/dev/null 2>&1 || true
AGENT_YAML=$(find "${WORKDIR}" -name agent.yaml -type f 2>/dev/null | head -1)
[ -n "${AGENT_YAML}" ] && "${ARCTL}" apply -f "${AGENT_YAML}" || true

demo_step "Deploy to the AWS Bedrock Runtime"
prompt_continue "Apply the Deployment"
arctl_apply <<EOF
apiVersion: ar.dev/v1alpha1
kind: Deployment
metadata:
  name: ${AGENT_NAME}-aws
spec:
  targetRef:
    kind: Agent
    name: ${AGENT_NAME}
    tag: "latest"
  runtimeRef:
    kind: Runtime
    name: ${AWS_RUNTIME}
EOF

demo_step "Deployment status"
"${ARCTL}" get deployments 2>&1 || true

prompt_continue "Demo complete — press Enter to clean up"
