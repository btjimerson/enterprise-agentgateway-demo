#!/bin/bash

# Installs the `arctl` CLI (ARCTL_VERSION), port-forwards the in-cluster registry
# server, and logs in headlessly via the OIDC resource-owner password grant
# so subsequent scripts have a valid bearer token.
#
# arctl resolution, in order:
#   1. $ARCTL_BIN if set + executable.
#   2. `command -v arctl` on $PATH (validated for the v2026.x CLI surface).
#   3. Install the pinned version via the official installer:
#        curl -sSL https://storage.googleapis.com/agentregistry-enterprise/install.sh \
#          | ARCTL_VERSION=$ARCTL_VERSION sh
#      → ~/.arctl/bin/arctl
#
# A version-compat guard rejects the OLD v0.0.x CLI (which has `mcp`/`agent`/
# `provider`/`role` subcommands instead of `get`/`apply`) with a clear message
# — that mismatch was the original cause of the install failure this rebuild
# fixes.
#
# Login uses the ar-cli-password public client (realm enables
# directAccessGrantsEnabled), matching the quickstart's CI/CD flow:
#   arctl user login --oidc-flow=password-credentials \
#     --oidc-client-id=ar-cli-password --oidc-username=... --oidc-password=...
# That login is only used for this script's install-time verify. We deliberately
# do NOT export a static ARCTL_API_TOKEN: it expires (and arctl's password-login
# session isn't refreshable here either), so a baked token causes 401s later. For
# ad-hoc commands use ./arctl.sh (mints a fresh bearer per call); demos mint fresh
# via demo/_common.sh (baseline admin token + per-user arctl_as).
#
# Usage: 04-install-arctl.sh [--cleanup]
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
BIN_DIR="${SCRIPT_DIR}/bin"
# The official installer drops arctl here.
ARCTL_HOME="${HOME}/.arctl"

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
  echo -e "${RED}Tearing down arctl session + port-forwards...${NC}"
  pkill -f "kubectl.* port-forward .* 12121:.*agentregistry-enterprise-server" 2>/dev/null || true
  rm -f "${BIN_DIR}/arctl-path.env"
  rm -f "${BIN_DIR}/arctl" 2>/dev/null || true
  # Only remove ~/.arctl if THIS script installed it (left a marker). Never
  # nuke a user's pre-existing arctl install.
  if [ -f "${BIN_DIR}/.arctl-installed-by-demo" ]; then
    rm -rf "${ARCTL_HOME}" 2>/dev/null || true
    rm -f "${BIN_DIR}/.arctl-installed-by-demo"
  fi
  echo -e "${GREEN}arctl cleanup complete.${NC}"
  exit 0
}

case "${1:-}" in
  --cleanup) MODE=cleanup ;;
  -h|--help) usage ;;
  "")        MODE=install ;;
  *)         usage ;;
esac

solo_kube_init

require_env CLUSTER_CONTEXT ARCTL_API_BASE_URL ARCTL_VERSION \
            AGENTREGISTRY_NAMESPACE \
            KEYCLOAK_ISSUER AR_CLI_PASSWORD_CLIENT_ID \
            DEMO_USER_ADMIN DEMO_USER_ADMIN_PASSWORD

[ "$MODE" = "cleanup" ] && cleanup

mkdir -p "${BIN_DIR}"

# ---- 1. Resolve / install arctl --------------------------------------------
# Validate that a candidate binary is the v2026.x declarative CLI, not the
# retired v0.0.x line.
arctl_is_compatible() {
  "$1" --help 2>/dev/null | grep -qE '^[[:space:]]+apply[[:space:]]' \
    && "$1" --help 2>/dev/null | grep -qE '^[[:space:]]+get[[:space:]]'
}

ARCTL=""
ARCTL_SOURCE=""
if [ -n "${ARCTL_BIN:-}" ] && [ -x "${ARCTL_BIN}" ]; then
  ARCTL="${ARCTL_BIN}"; ARCTL_SOURCE="ARCTL_BIN override"
elif command -v arctl >/dev/null 2>&1; then
  ARCTL="$(command -v arctl)"; ARCTL_SOURCE="\$PATH"
elif [ -x "${ARCTL_HOME}/bin/arctl" ]; then
  ARCTL="${ARCTL_HOME}/bin/arctl"
  # Display label only — printed back to the user, never used as a path, so the
  # literal ~ is intended (and shorter to read than the expanded $HOME).
  # shellcheck disable=SC2088
  ARCTL_SOURCE="~/.arctl/bin"
fi

if [ -n "${ARCTL}" ] && ! arctl_is_compatible "${ARCTL}"; then
  echo -e "${YELLOW}Found arctl at ${ARCTL} (${ARCTL_SOURCE}) but it is NOT the v2026.x CLI${NC}"
  echo -e "${YELLOW}(missing 'get'/'apply' — likely the retired v0.0.x line). Reinstalling.${NC}"
  ARCTL=""
fi

if [ -z "${ARCTL}" ]; then
  echo ""
  echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
  echo -e "${BLUE}  Installing arctl ${ARCTL_VERSION} via the official installer${NC}"
  echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
  if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}ERROR: curl is required to install arctl.${NC}" >&2
    exit 1
  fi
  if ! curl -sSL https://storage.googleapis.com/agentregistry-enterprise/install.sh \
       | ARCTL_VERSION="${ARCTL_VERSION}" sh; then
    echo -e "${RED}ERROR: arctl install.sh failed.${NC}" >&2
    exit 1
  fi
  touch "${BIN_DIR}/.arctl-installed-by-demo"
  if [ -x "${ARCTL_HOME}/bin/arctl" ]; then
    ARCTL="${ARCTL_HOME}/bin/arctl"
  elif command -v arctl >/dev/null 2>&1; then
    ARCTL="$(command -v arctl)"
  fi
  ARCTL_SOURCE="fresh install (${ARCTL_VERSION})"
fi

if [ -z "${ARCTL}" ] || ! arctl_is_compatible "${ARCTL}"; then
  echo -e "${RED}ERROR: could not resolve a compatible arctl (v2026.x) binary.${NC}" >&2
  exit 1
fi

echo -e "${GREEN}Using arctl from:${NC} ${ARCTL} (${ARCTL_SOURCE})"
"${ARCTL}" version 2>/dev/null | head -3 || true

# Symlink into bin/ so demo/_common.sh's $SCRIPT_DIR/../bin/arctl lookup works.
ln -sf "${ARCTL}" "${BIN_DIR}/arctl"

# ---- 2. Port-forward the registry server -----------------------------------
echo ""
echo -e "${BLUE}Starting registry port-forward localhost:12121 → svc/agentregistry-enterprise-server${NC}"
pkill -f "kubectl.* port-forward .* 12121:.*agentregistry-enterprise-server" 2>/dev/null || true
sleep 0.5
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
  port-forward svc/agentregistry-enterprise-server 12121:12121 \
  >/tmp/are-api-pf.log 2>&1 &
disown "$!" 2>/dev/null || true
for _ in $(seq 1 30); do
  if curl -sSf --max-time 2 "${ARCTL_API_BASE_URL}/v0/health" >/dev/null 2>&1 \
     || curl -sSf --max-time 2 "${ARCTL_API_BASE_URL}/v0/version" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# ---- 3. Headless OIDC login (resource-owner password grant) ----------------
# Logs in against the external Keycloak (consolidated 'solo' realm).
OIDC_ISSUER="${KEYCLOAK_ISSUER}"
export OIDC_ISSUER

echo ""
echo -e "${BLUE}Logging in to ${OIDC_ISSUER} as ${DEMO_USER_ADMIN} (password-credentials flow)...${NC}"
if ! "${ARCTL}" user login \
      --oidc-flow=password-credentials \
      --oidc-client-id="${AR_CLI_PASSWORD_CLIENT_ID}" \
      --oidc-username="${DEMO_USER_ADMIN}" \
      --oidc-password="${DEMO_USER_ADMIN_PASSWORD}" \
      --registry-url "${ARCTL_API_BASE_URL}"; then
  echo -e "${RED}ERROR: arctl user login failed.${NC}" >&2
  echo -e "${RED}  Check that your Keycloak is reachable at ${OIDC_ISSUER} and${NC}" >&2
  echo -e "${RED}  that the '${AR_CLI_PASSWORD_CLIENT_ID}' client has directAccessGrantsEnabled.${NC}" >&2
  exit 1
fi

# Persist the resolved binary for direnv / subsequent shells. We deliberately do
# NOT bake the access token: a static ARCTL_API_TOKEN expires (and arctl prefers
# it over its own session), causing 401s on later calls — and arctl's own
# password-login session isn't refreshable here either. Ad-hoc commands go
# through ./arctl.sh (fresh bearer per call); demos mint fresh in _common.sh.
cat > "${BIN_DIR}/arctl-path.env" <<EOF
# Generated by 04-install-arctl.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Source from .envrc to keep arctl on PATH in shell state:
#   [ -f "\$PWD/bin/arctl-path.env" ] && source "\$PWD/bin/arctl-path.env"
export ARCTL_BIN="${ARCTL}"
EOF

# ---- 4. End-to-end verify --------------------------------------------------
# Verify using the fresh login session we just created. A stale ARCTL_API_TOKEN
# in the environment (e.g. an old value direnv still has loaded from a previous
# handoff file) is the default for --registry-token and would override the
# session, failing the verify with a 401 "token has expired". Clear it here.
unset ARCTL_API_TOKEN
echo -e "${BLUE}Verifying against the registry...${NC}"
echo -e "${BLUE}  arctl user whoami${NC}"
if ! "${ARCTL}" user whoami --registry-url "${ARCTL_API_BASE_URL}"; then
  echo -e "${RED}ERROR: 'arctl user whoami' failed against ${ARCTL_API_BASE_URL}.${NC}" >&2
  echo -e "${RED}  Diagnostic: kubectl -n ${AGENTREGISTRY_NAMESPACE} logs deploy/agentregistry-enterprise-server --tail=50${NC}" >&2
  exit 1
fi
echo -e "${BLUE}  arctl get mcp${NC}"
if ! "${ARCTL}" get mcp --registry-url "${ARCTL_API_BASE_URL}" >/dev/null 2>&1; then
  echo -e "${RED}ERROR: 'arctl get mcp' failed (an empty catalog is fine; an auth error is not).${NC}" >&2
  echo -e "${RED}  Diagnostic: kubectl -n ${AGENTREGISTRY_NAMESPACE} logs deploy/agentregistry-enterprise-server --tail=50${NC}" >&2
  exit 1
fi

echo ""
echo -e "${GREEN}arctl wired up with an OIDC bearer token.${NC}"
echo -e "${GREEN}Binary:${NC}          ${ARCTL}"
echo -e "${GREEN}Registry URL:${NC}    ${ARCTL_API_BASE_URL}"
echo -e "${GREEN}Port-forward:${NC}    localhost:12121 → agentregistry-enterprise-server"
echo -e "${GREEN}Session:${NC}         ${DEMO_USER_ADMIN} (admins → superuser)"
echo -e "${GREEN}  written to:${NC}    ${BIN_DIR}/arctl-path.env"
echo -e "${YELLOW}Add to .envrc so subsequent shells keep arctl on PATH:${NC}"
echo -e "${YELLOW}  [ -f \$PWD/bin/arctl-path.env ] && source \$PWD/bin/arctl-path.env${NC}"
echo -e "${GREEN}Next:${NC}            ./05-register-runtimes.sh"
