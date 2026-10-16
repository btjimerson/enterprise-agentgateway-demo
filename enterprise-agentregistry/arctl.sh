#!/bin/bash

# Thin arctl wrapper that "just works" for ad-hoc commands:
#   ./arctl.sh get runtimes
#   ./arctl.sh user whoami
#
# It (1) ensures a localhost:12121 port-forward to the registry server, and
# (2) mints a FRESH OIDC bearer token and passes it as ARCTL_API_TOKEN for this
# one invocation.
#
# Why mint per call instead of `arctl user login`: arctl's password-credentials
# login does not persist a refreshable session here, so its keychain session
# expires and can't renew ("no refresh token available"). A freshly-minted
# bearer (valid for the realm's accessTokenLifespan) is the reliable path — the
# same mechanism the demo scripts (demo/_common.sh) use. No token is written to
# disk or the environment, so nothing goes stale.
#
# Run a demo as a non-admin user via the demo helpers instead (arctl_as).
#
# Author: Brian Jimerson

set -euo pipefail

RED='\033[0;31m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${AGENTREGISTRY_NAMESPACE:=agentregistry-system}"
: "${ARCTL_API_BASE_URL:=http://localhost:12121}"
: "${AR_CLI_PASSWORD_CLIENT_ID:=ar-cli-password}"
: "${KEYCLOAK_REALM:=solo}"
ARCTL="${ARCTL_BIN:-${SCRIPT_DIR}/bin/arctl}"
REGISTRY_SVC="agentregistry-enterprise-server"
CTX="${CLUSTER_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}"

for v in KEYCLOAK_ISSUER DEMO_USER_ADMIN DEMO_USER_ADMIN_PASSWORD; do
  if [ -z "${!v:-}" ]; then
    echo -e "${RED}ERROR: $v is not set. Source your .envrc first (direnv allow).${NC}" >&2
    exit 1
  fi
done
if [ ! -x "${ARCTL}" ]; then
  echo -e "${RED}ERROR: arctl not found at ${ARCTL}. Run ./04-install-arctl.sh first.${NC}" >&2
  exit 1
fi

_registry_up() {
  curl -sf --max-time 2 "${ARCTL_API_BASE_URL}/v0/health"  >/dev/null 2>&1 \
    || curl -sf --max-time 2 "${ARCTL_API_BASE_URL}/v0/version" >/dev/null 2>&1
}

# Ensure the port-forward (start a backgrounded, disowned one if nothing answers).
if ! _registry_up; then
  [ -n "${CTX}" ] || { echo -e "${RED}ERROR: no kube-context (set CLUSTER_CONTEXT).${NC}" >&2; exit 1; }
  kubectl --context "${CTX}" -n "${AGENTREGISTRY_NAMESPACE}" \
    port-forward "svc/${REGISTRY_SVC}" 12121:12121 >/tmp/enterprise-ar-registry-pf.log 2>&1 &
  disown "$!" 2>/dev/null || true
  for _ in $(seq 1 20); do _registry_up && break; sleep 0.5; done
fi

# Mint a fresh bearer (ROPG via the public ar-cli-password client).
TOKEN="$(curl -sS --max-time 10 \
  --data-urlencode "client_id=${AR_CLI_PASSWORD_CLIENT_ID}" \
  --data-urlencode "username=${DEMO_USER_ADMIN}" \
  --data-urlencode "password=${DEMO_USER_ADMIN_PASSWORD}" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "scope=openid" \
  "${KEYCLOAK_ISSUER}/protocol/openid-connect/token" | jq -r '.access_token // empty')"
if [ -z "${TOKEN}" ]; then
  echo -e "${RED}ERROR: failed to mint a token from ${KEYCLOAK_ISSUER}.${NC}" >&2
  echo -e "${RED}  Check your Keycloak is reachable and ${AR_CLI_PASSWORD_CLIENT_ID} has directAccessGrantsEnabled.${NC}" >&2
  exit 1
fi

exec env ARCTL_API_TOKEN="${TOKEN}" "${ARCTL}" --registry-url "${ARCTL_API_BASE_URL}" "$@"
