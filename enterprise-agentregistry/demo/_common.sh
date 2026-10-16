#!/bin/bash
# shellcheck disable=SC2034
#   This is a LIBRARY. The color palette and a few config vars below are read
#   by the scripts that source it, which shellcheck cannot see across files.
# Helpers for demo scripts under demo/.
#
# Exports:
#   - arctl_as <user> <pass> -- <arctl args...>  run one arctl call as the
#       named user (mints a fresh token via the ar-cli-password ROPG client),
#       leaving the caller's baseline session intact.
#   - arctl_apply                                read a YAML doc on stdin and
#       `arctl apply -f -` it (heredoc-friendly).
#   - get_jwt <user> <pass>                      Keycloak password grant → prints access_token
#   - jwt_decode <token>                         pretty-print JWT payload
#   - ensure_registry_portforward                localhost:12121 → svc/agentregistry-enterprise-server
#   - ensure_keycloak_portforward                points KEYCLOAK_URL at the external Keycloak
#   - show_file / demo_header / demo_step / prompt_continue / require_cmds / require_arctl

: "${AGENTREGISTRY_NAMESPACE:=agentregistry-system}"
: "${AGENTREGISTRY_RELEASE:=agentregistry}"
: "${KAGENT_NAMESPACE:=kagent}"
: "${KEYCLOAK_REALM:=solo}"
# Public client used for headless ROPG token minting (directAccessGrantsEnabled).
: "${AR_CLI_PASSWORD_CLIENT_ID:=ar-cli-password}"
: "${KEYCLOAK_ROLE_CLAIM:=Groups}"
: "${DEMO_APPS_NAMESPACE:=enterprise-ar-demo}"

# The server Service. Chart fullname is fixed regardless of release.
REGISTRY_SVC="agentregistry-enterprise-server"

# Path to arctl binary (04-install-arctl.sh symlinks it here).
SCRIPT_DIR_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCTL="${SCRIPT_DIR_COMMON}/../bin/arctl"

# Confirm + pin the kube-context: lets you pick the right cluster
# and pins every kubectl/helm call so a mid-demo `kubectl config use-context`
# can't redirect it. Skips the prompt when non-interactive or DEMO_AUTO=1.
# shellcheck source=../../common/kube-context.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../common" && pwd)/kube-context.sh"
solo_kube_init

# Auto-source the arctl handoff file so ARCTL_BIN is set in every script
# regardless of the user's .envrc state (no static token — we mint fresh bearers
# below: a baseline admin token and per-user tokens via arctl_as).
# Missing before first install is fine. (Keycloak is the external server
# — its URL/secrets come from .envrc as constants, no handoff files anymore.)
if [ -f "${SCRIPT_DIR_COMMON}/../bin/arctl-path.env" ]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR_COMMON}/../bin/arctl-path.env"
fi

# External Keycloak (see ../keycloak/). The issuer + JWKS are public
# HTTPS, reachable by the browser, the registry/kagent, and these demo scripts
# directly — no port-forward.
: "${KEYCLOAK_EXTERNAL_URL:=}"
: "${KEYCLOAK_ISSUER:=${KEYCLOAK_EXTERNAL_URL}/realms/${KEYCLOAK_REALM}}"
: "${KEYCLOAK_JWKS_URL:=${KEYCLOAK_ISSUER}/protocol/openid-connect/certs}"
# Bare host derived UNCONDITIONALLY from the issuer (strip scheme, then path) so
# a stale full-URL KEYCLOAK_EXTERNAL_HOST in the environment can't leak.
_kc_no_scheme="${KEYCLOAK_ISSUER#*://}"
KEYCLOAK_EXTERNAL_HOST="${_kc_no_scheme%%/*}"
export KEYCLOAK_ISSUER KEYCLOAK_JWKS_URL KEYCLOAK_REALM KEYCLOAK_EXTERNAL_HOST

BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

# ---- port-forwarding -------------------------------------------------------

_PF_PIDS=()

_kill_stale_pf_on_port() {
  local port="$1"
  pkill -f "kubectl.* port-forward .* ${port}:" 2>/dev/null || true
  sleep 0.3
}

_cleanup_portforwards() {
  for pid in "${_PF_PIDS[@]:-}"; do
    [ -n "${pid}" ] || continue
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
}
trap _cleanup_portforwards EXIT

ensure_registry_portforward() {
  if [ -n "${REGISTRY_URL:-}" ]; then return; fi
  _kill_stale_pf_on_port 12121
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
    port-forward "svc/${REGISTRY_SVC}" 12121:12121 \
    >/tmp/enterprise-ar-registry-pf.log 2>&1 &
  local pid=$!
  _PF_PIDS+=("${pid}")
  disown "${pid}" 2>/dev/null || true
  for _ in $(seq 1 30); do
    if curl -sS --max-time 2 http://localhost:12121/v0/health >/dev/null 2>&1 \
       || curl -sS --max-time 2 http://localhost:12121/v0/version >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done
  export REGISTRY_URL="http://localhost:12121"
  # arctl reads ARCTL_API_BASE_URL as the default --registry-url (no /v0 suffix
  # — arctl appends the API path itself).
  export ARCTL_API_BASE_URL="${REGISTRY_URL}"
}

ensure_keycloak_portforward() {
  # Keycloak is an EXTERNAL server (public HTTPS) — no port-forward.
  # Just point KEYCLOAK_URL at it for the token-minting helpers below.
  export KEYCLOAK_URL="${KEYCLOAK_URL:-${KEYCLOAK_EXTERNAL_URL:-}}"
}

# ---- JWT -------------------------------------------------------------------

get_jwt() {
  local user="$1" pass="$2"
  ensure_keycloak_portforward
  local resp token
  # ROPG against the public ar-cli-password client. scope=openid only — the
  # Groups claim comes from a client protocolMapper, not a requestable scope.
  if ! resp=$(curl -sS --max-time 10 \
        -d "client_id=${AR_CLI_PASSWORD_CLIENT_ID}" \
        -d "username=${user}" \
        -d "password=${pass}" \
        -d "grant_type=password" \
        -d "scope=openid" \
        "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" 2>&1); then
    echo "ERROR: failed to reach Keycloak at ${KEYCLOAK_URL}: ${resp}" >&2
    return 1
  fi
  token=$(printf '%s' "${resp}" | jq -r '.access_token // empty')
  if [ -z "${token}" ]; then
    echo "ERROR: Keycloak did not return an access_token. Raw response:" >&2
    echo "${resp}" >&2
    return 1
  fi
  printf '%s' "${token}"
}

jwt_decode() {
  local token="$1"
  if [ -z "${token}" ] || [ "${token}" = "null" ]; then
    echo "(empty or null token)" >&2
    return 1
  fi
  local payload pad
  payload=$(printf '%s' "${token}" | cut -d. -f2)
  pad=$(( 4 - ${#payload} % 4 ))
  [ $pad -lt 4 ] && payload="${payload}$(printf '=%.0s' $(seq 1 $pad))"
  printf '%s' "${payload}" | tr '_-' '/+' | base64 -d 2>/dev/null | jq .
}

# ---- arctl helpers ---------------------------------------------------------
#
# The registry validates Keycloak RS256 tokens. arctl's own password-credentials
# login isn't refreshable here, so we authenticate by passing a minted bearer via
# ARCTL_API_TOKEN: a fresh admin token for the baseline session below, and a
# per-user token for arctl_as (which leaves the baseline untouched).

# Baseline session: mint a fresh admin bearer once per script run so direct
# `${ARCTL} get …` calls work. Skipped if the caller already exported a token.
if [ -z "${ARCTL_API_TOKEN:-}" ]; then
  ARCTL_API_TOKEN="$(get_jwt "${DEMO_USER_ADMIN:-admin-user}" "${DEMO_USER_ADMIN_PASSWORD:?set DEMO_USER_ADMIN_PASSWORD in .envrc (see .envrc.sample)}" 2>/dev/null || true)"
  [ -n "${ARCTL_API_TOKEN}" ] && export ARCTL_API_TOKEN
fi

arctl_as() {
  local user="$1" pass="$2"
  shift 2
  [ "$1" = "--" ] && shift
  local token
  token=$(get_jwt "${user}" "${pass}") || {
    echo -e "${RED}  failed to mint Keycloak token for ${user}${NC}" >&2
    return 1
  }
  ARCTL_API_TOKEN="${token}" "${ARCTL}" "$@"
}

# arctl_apply: read one or more YAML docs from stdin and apply them.
#   arctl_apply <<EOF
#   apiVersion: ar.dev/v1alpha1
#   kind: Runtime
#   ...
#   EOF
arctl_apply() {
  "${ARCTL}" apply -f -
}

# ---- ui helpers ------------------------------------------------------------

demo_header() {
  echo ""
  echo -e "${BLUE}${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}${BOLD}  $*${NC}"
  echo -e "${BLUE}${BOLD}════════════════════════════════════════════════════════════${NC}"
}

demo_step() {
  echo ""
  echo -e "${YELLOW}${BOLD}▶ $*${NC}"
}

show_file() {
  local f="$1"
  echo ""
  echo -e "${CYAN}--- ${f} ---${NC}"
  cat "${f}"
  echo -e "${CYAN}--- end ---${NC}"
}

apply_and_wait() {
  local f="$1"
  kubectl --context "${CLUSTER_CONTEXT}" apply -f "${f}"
  sleep 3
}

delete_and_wait() {
  local f="$1"
  kubectl --context "${CLUSTER_CONTEXT}" delete -f "${f}" --ignore-not-found >/dev/null 2>&1 || true
  sleep 2
}

prompt_continue() {
  if [ "${DEMO_AUTO:-0}" = "1" ]; then return; fi
  local msg="${1:-Continue}"
  read -r -p $'\n'"${msg} (press Enter)... " _
}

require_cmds() {
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      echo -e "${RED}ERROR: required command '$c' not on PATH.${NC}" >&2
      exit 1
    fi
  done
}

require_arctl() {
  if [ ! -x "${ARCTL}" ]; then
    echo -e "${RED}ERROR: arctl binary not found at ${ARCTL}.${NC}" >&2
    echo -e "${RED}       Run ../04-install-arctl.sh first.${NC}" >&2
    exit 1
  fi
}
