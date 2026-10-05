#!/usr/bin/env bash
# Shared pre-flight check for KEYCLOAK_ISSUER.
#
# Every Solo demo points at ONE long-lived external Keycloak, and four install
# scripts feed ${KEYCLOAK_ISSUER} straight into a Helm chart. `require_env` only
# proves the variable is non-empty, which the `.envrc.sample` placeholder
# (https://keycloak.example.com) satisfies perfectly well. Installing with it
# does not fail at install time — helm reports success, and ~4 minutes later
# ui-backend exits `fatal` on OIDC discovery, never reaches its ClickHouse
# migrations, and the FIRST thing the operator sees is a healthy sidecar
# complaining "Database platformdb does not exist" in a different container.
# That message points nowhere near OIDC or .envrc.
#
# So: probe the issuer for real instead of scanning it for known-bad strings. A
# live GET of the discovery document catches the placeholder, a typo'd host, a
# Keycloak that is down or not yet provisioned, and a realm that does not exist
# — one check, four failure modes, and it costs a couple of seconds.
#
# LIMITATION, on purpose: this runs on the OPERATOR'S laptop, so it proves the
# issuer is reachable from THERE, not from inside the cluster. A split-horizon
# DNS setup or a cluster egress rule can still break the in-cluster lookup that
# ui-backend performs. This is a fast pre-flight, not a guarantee.
#
# Usage:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../common" && pwd)/keycloak-issuer.sh"
#   require_env KEYCLOAK_ISSUER ...
#   solo_verify_keycloak_issuer            # uses ${KEYCLOAK_ISSUER}
#   solo_verify_keycloak_issuer "$SOME_OTHER_ISSUER"
#
# Escape hatches:
#   SOLO_SKIP_ISSUER_CHECK=1   skip entirely (air-gapped rig, offline CI)
#   SOLO_ISSUER_CHECK_TIMEOUT  per-request timeout in seconds (default 10)

_SKI_BLUE='\033[0;34m'; _SKI_GREEN='\033[0;32m'; _SKI_RED='\033[0;31m'
_SKI_YELLOW='\033[0;33m'; _SKI_NC='\033[0m'

: "${SOLO_ISSUER_CHECK_TIMEOUT:=10}"

# Map curl's exit code onto the thing the operator actually has to go fix.
_ski_curl_hint() {
  case "$1" in
    6)  echo "DNS does not resolve that host — is KEYCLOAK_EXTERNAL_URL still the .envrc.sample placeholder?" ;;
    7)  echo "host resolves but refused the connection — is the Keycloak VM up?" ;;
    28) echo "timed out after ${SOLO_ISSUER_CHECK_TIMEOUT}s — firewall, or the VM is wedged." ;;
    35|60) echo "TLS handshake failed — check the Caddy certificate on the Keycloak VM." ;;
    *)  echo "curl exit ${1}." ;;
  esac
}

# Verify an OIDC issuer serves a discovery document whose `issuer` claim agrees
# with the URL we are about to hand to Helm. $1 = issuer (default KEYCLOAK_ISSUER).
solo_verify_keycloak_issuer() {
  local issuer="${1:-${KEYCLOAK_ISSUER:-}}"

  if [ "${SOLO_SKIP_ISSUER_CHECK:-0}" = "1" ]; then
    echo -e "${_SKI_YELLOW}  Skipping Keycloak issuer check (SOLO_SKIP_ISSUER_CHECK=1).${_SKI_NC}" >&2
    return 0
  fi

  if [ -z "${issuer}" ]; then
    echo -e "${_SKI_RED}ERROR: KEYCLOAK_ISSUER is empty. Source your .envrc first.${_SKI_NC}" >&2
    return 1
  fi

  # Tolerate a trailing slash so we never build a '//.well-known' URL.
  local disco="${issuer%/}/.well-known/openid-configuration"
  echo -e "${_SKI_BLUE}  Verifying Keycloak issuer: ${issuer}${_SKI_NC}"

  local body_f code rc=0
  body_f="$(mktemp)"
  # `|| rc=$?` keeps a non-zero curl from tripping the caller's `set -e` before
  # we get to print a message that explains what went wrong.
  code="$(curl -sS --max-time "${SOLO_ISSUER_CHECK_TIMEOUT}" \
            -o "${body_f}" -w '%{http_code}' "${disco}" 2>/dev/null)" || rc=$?

  if [ "${rc}" -ne 0 ]; then
    echo -e "${_SKI_RED}ERROR: cannot reach the Keycloak issuer.${_SKI_NC}" >&2
    echo -e "${_SKI_RED}       GET ${disco}${_SKI_NC}" >&2
    echo -e "${_SKI_RED}       $(_ski_curl_hint "${rc}")${_SKI_NC}" >&2
    echo -e "${_SKI_YELLOW}       Editing .envrc revokes direnv's allow — run 'direnv allow' and${_SKI_NC}" >&2
    echo -e "${_SKI_YELLOW}       confirm: echo \$KEYCLOAK_ISSUER${_SKI_NC}" >&2
    rm -f "${body_f}"
    return 1
  fi

  if [ "${code}" != "200" ]; then
    echo -e "${_SKI_RED}ERROR: Keycloak issuer returned HTTP ${code}, expected 200.${_SKI_NC}" >&2
    echo -e "${_SKI_RED}       GET ${disco}${_SKI_NC}" >&2
    if [ "${code}" = "404" ]; then
      # Name the realm we actually probed, not ${KEYCLOAK_REALM} — the caller may
      # have passed an explicit issuer that disagrees with the environment.
      local realm="${issuer##*/realms/}"
      [ "${realm}" = "${issuer}" ] && realm="<none in URL>"
      echo -e "${_SKI_RED}       The host is up but has no '${realm%/}' realm — import keycloak/realm-agentgateway-demo.json (see README).${_SKI_NC}" >&2
    fi
    rm -f "${body_f}"
    return 1
  fi

  # The claim must match what we hand to Helm: Keycloak signs tokens with the
  # issuer IT believes it has, so a mismatch here becomes a token-validation
  # failure at login rather than an install failure.
  if command -v jq >/dev/null 2>&1; then
    local claimed
    claimed="$(jq -r '.issuer // empty' "${body_f}" 2>/dev/null || true)"
    if [ -n "${claimed}" ] && [ "${claimed%/}" != "${issuer%/}" ]; then
      echo -e "${_SKI_RED}ERROR: issuer mismatch — tokens would fail validation at login.${_SKI_NC}" >&2
      echo -e "${_SKI_RED}       KEYCLOAK_ISSUER: ${issuer}${_SKI_NC}" >&2
      echo -e "${_SKI_RED}       Keycloak claims: ${claimed}${_SKI_NC}" >&2
      rm -f "${body_f}"
      return 1
    fi
  fi

  rm -f "${body_f}"
  echo -e "${_SKI_GREEN}  Keycloak issuer OK.${_SKI_NC}"
}
