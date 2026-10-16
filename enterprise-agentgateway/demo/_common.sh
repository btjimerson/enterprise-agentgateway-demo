#!/bin/bash
# shellcheck disable=SC2034
#   This is a LIBRARY. The color palette and a few config vars below are read
#   by the scripts that source it, which shellcheck cannot see across files.
# Shared helpers for demo scripts under demo/.
#
# Agentgateway-specific port-forward targets (svc/agentgateway-proxy, the control-plane STS on
# svc/enterprise-agentgateway:7777) and the extra HTTP/MCP helpers the
# agentgateway demos need.
#
# Exports:
#   - gw_post <path> [curl args...]     POST through the gateway, pretty-print JSON
#   - gw_curl <method> <path> [args...] method-agnostic variant
#   - get_jwt <user> <pass>             Keycloak password grant, prints access_token
#   - jwt_decode <token>                pretty-print JWT payload
#   - mcp_first_json <file>             first JSON object out of an SSE-or-JSON body
#   - ensure_gateway_portforward        localhost:8080 → svc/agentgateway-proxy
#   - ensure_keycloak_portforward       no-op; Keycloak is external (public HTTPS)
#   - ensure_sts_portforward            localhost:17777 → svc/enterprise-agentgateway:7777
#   - show_file <path>                  cat with header/footer
#   - apply_and_wait <path>             kubectl apply + brief xDS settle
#   - delete_and_wait <path>            kubectl delete --ignore-not-found + settle
#   - demo_header / demo_step           consistent ANSI output
#   - prompt_continue [msg]             pause unless DEMO_AUTO=1

: "${AGENTGATEWAY_NAMESPACE:=agentgateway-system}"
: "${DEMO_APPS_NAMESPACE:=agentgateway-demo}"
: "${KEYCLOAK_REALM:=solo}"
: "${KEYCLOAK_CLIENT_ID:=agw-client}"

# Confirm + pin the kube-context: lets you pick the right cluster
# and pins every kubectl/helm call so a mid-demo `kubectl config use-context`
# can't redirect it. Skips the prompt when non-interactive or DEMO_AUTO=1.
# shellcheck source=../../common/kube-context.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../common" && pwd)/kube-context.sh"
solo_kube_init

# External Keycloak (see ../../keycloak/). The issuer + JWKS are public
# HTTPS, reachable by the browser, the gateway, and these demo scripts directly
# — no port-forward. Demos render ${KEYCLOAK_ISSUER} into policy-jwt.yaml via
# apply_and_wait's envsubst.
: "${KEYCLOAK_EXTERNAL_URL:=}"
: "${KEYCLOAK_ISSUER:=${KEYCLOAK_EXTERNAL_URL}/realms/${KEYCLOAK_REALM}}"
: "${KEYCLOAK_JWKS_URL:=${KEYCLOAK_ISSUER}/protocol/openid-connect/certs}"
# Bare host for the keycloak-ext ExternalName Service in policy-jwt.yaml.
# Derived UNCONDITIONALLY from the issuer (strip scheme, then path) so a stale
# or full-URL KEYCLOAK_EXTERNAL_HOST in the environment can't leak the scheme
# into the Service's externalName (which fails RFC-1123 validation).
_kc_no_scheme="${KEYCLOAK_ISSUER#*://}"
KEYCLOAK_EXTERNAL_HOST="${_kc_no_scheme%%/*}"
# Exported so apply_and_wait's envsubst can render them into manifests.
export KEYCLOAK_ISSUER KEYCLOAK_JWKS_URL KEYCLOAK_REALM KEYCLOAK_EXTERNAL_HOST

BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

# ---- port-forwarding -------------------------------------------------------

# Refuse to forward onto, or accept, a port some other process (Docker, say) already holds. A
# kubectl port-forward binds 127.0.0.1 and [::1] and Docker publishes on *, and macOS allows
# both without an error, so a "something answers on this port" probe passes and requests can
# reach the wrong service.
# shellcheck source=../../common/port-check.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../common" && pwd)/port-check.sh"

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

ensure_gateway_portforward() {
  if [ -n "${GATEWAY_URL:-}" ]; then return; fi
  local svc
  svc=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    get svc -l gateway.networking.k8s.io/gateway-name=agentgateway-proxy \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -z "${svc}" ] && svc="agentgateway-proxy"
  _kill_stale_pf_on_port 8080
  port_forward_conflict 8080 || exit 1
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    port-forward "svc/${svc}" 8080:8080 >/tmp/agw-gateway-pf.log 2>&1 &
  local pid=$!
  _PF_PIDS+=("${pid}")
  disown "${pid}" 2>/dev/null || true
  # TCP-connect probe — avoids GET / logging a noisy 404 on the proxy.
  for _ in $(seq 1 20); do
    if (exec 3<>/dev/tcp/localhost/8080) 2>/dev/null; then
      exec 3<&- 3>&-
      break
    fi
    sleep 0.5
  done
  export GATEWAY_URL="http://localhost:8080"
}

ensure_keycloak_portforward() {
  # Keycloak is the shared EXTERNAL server (public HTTPS) — no port-forward.
  # Just point KEYCLOAK_URL at it for the token-minting helpers below.
  export KEYCLOAK_URL="${KEYCLOAK_URL:-${KEYCLOAK_EXTERNAL_URL:-}}"
}

# Port-forward the Solo Enterprise UI so a demo can hand you a URL
# your browser can actually open.
#
# Deliberately does NOT guard on SOLO_UI_URL being merely set: .envrc exports
# SOLO_UI_URL=http://localhost:4000 by default, so a naive `[ -n ... ] && return`
# would skip the forward every time and silently do nothing. Instead:
#   1. a non-localhost SOLO_UI_URL (the UI's LoadBalancer) means don't forward
#   2. an already-listening port means someone has their own forward — leave it
#   3. otherwise start one and register it for teardown
#
# Note the service exposes several ports and only 80 is the web UI
# (80 -> targetPort 8090). Forward 4000:80, matching ui-login.sh.
ensure_ui_portforward() {
  local port="${UI_PORT:-4000}"
  case "${SOLO_UI_URL:-}" in
    ""|*localhost*|*127.0.0.1*) ;;
    *) return ;;                  # pointed at a real LB — nothing to forward
  esac
  if (exec 3<>/dev/tcp/localhost/"${port}") 2>/dev/null; then
    exec 3<&- 3>&-                # already reachable; don't kill someone's forward
    # ...but make sure it IS a forward (kubectl/ssh) and not, say, a Docker container.
    port_forward_conflict "${port}" || exit 1
    export SOLO_UI_URL="http://localhost:${port}"
    return
  fi
  _kill_stale_pf_on_port "${port}"
  port_forward_conflict "${port}" || exit 1
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    port-forward svc/solo-enterprise-ui "${port}:80" >/tmp/agw-ui-pf.log 2>&1 &
  local pid=$!
  _PF_PIDS+=("${pid}")
  disown "${pid}" 2>/dev/null || true
  for _ in $(seq 1 20); do
    if (exec 3<>/dev/tcp/localhost/"${port}") 2>/dev/null; then
      exec 3<&- 3>&-
      break
    fi
    sleep 0.5
  done
  export SOLO_UI_URL="http://localhost:${port}"
}

# Port-forward the control-plane STS listener (RFC 8693 token exchange).
# Only works once 09-install-obo.sh has been run (enables tokenExchange).
ensure_sts_portforward() {
  if [ -n "${STS_URL:-}" ]; then return; fi
  _kill_stale_pf_on_port 17777
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    port-forward svc/enterprise-agentgateway 17777:7777 >/tmp/agw-sts-pf.log 2>&1 &
  local pid=$!
  _PF_PIDS+=("${pid}")
  disown "${pid}" 2>/dev/null || true
  for _ in $(seq 1 20); do
    if (exec 3<>/dev/tcp/localhost/17777) 2>/dev/null; then
      exec 3<&- 3>&-
      break
    fi
    sleep 0.5
  done
  export STS_URL="http://localhost:17777"
}

# ---- JWT -------------------------------------------------------------------

get_jwt() {
  local user="$1" pass="$2"
  # Retry transient connectivity failures — a brief Keycloak restart can kill
  # the port-forward mid-grant (curl exits non-zero / 0ms refusal). Each retry
  # re-establishes the port-forward via ensure_keycloak_portforward. A genuine
  # Keycloak auth error (e.g. invalid_grant) is NOT transient, so fail fast.
  local attempt resp token
  for attempt in 1 2 3; do
    ensure_keycloak_portforward
    if resp=$(curl -sS --max-time 10 \
          -d "client_id=${KEYCLOAK_CLIENT_ID}" \
          -d "username=${user}" \
          -d "password=${pass}" \
          -d "grant_type=password" \
          "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" 2>&1); then
      token=$(printf '%s' "${resp}" | sed -nE 's/.*"access_token":"([^"]+)".*/\1/p')
      if [ -n "${token}" ]; then
        printf '%s' "${token}"
        return 0
      fi
      # Got a response but no token — if Keycloak returned an error, it's a
      # real failure (bad creds/client), not a blip. Don't retry.
      if printf '%s' "${resp}" | grep -q '"error"'; then
        echo "ERROR: Keycloak rejected the token request:" >&2
        echo "${resp}" >&2
        return 1
      fi
    fi
    # Connectivity failure or empty/unknown response: drop the (likely dead)
    # managed port-forward so the next attempt rebuilds it, then back off.
    if [ "${KEYCLOAK_URL:-}" = "http://localhost:18080" ]; then
      _kill_stale_pf_on_port 18080
    fi
    [ "${attempt}" -lt 3 ] && { echo "  Keycloak unreachable (attempt ${attempt}/3); retrying..." >&2; sleep 2; }
  done
  echo "ERROR: failed to reach Keycloak at ${KEYCLOAK_URL:-<unset>} after 3 attempts." >&2
  echo "       Is Keycloak (${KEYCLOAK_EXTERNAL_URL:-<KEYCLOAK_EXTERNAL_URL unset>}) reachable?" >&2
  [ -n "${resp:-}" ] && echo "       Last response: ${resp}" >&2
  return 1
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

# ---- gateway requests ------------------------------------------------------

# gw_post <path> [extra curl args...]
gw_post() {
  local path="$1"; shift
  ensure_gateway_portforward
  local out status
  out=$(mktemp)
  status=$(curl -sS -o "${out}" -w "%{http_code}" -X POST \
    "${GATEWAY_URL}${path}" "$@" 2>/dev/null || echo "000")
  echo -e "${CYAN}# HTTP ${status}${NC}"
  if command -v jq >/dev/null && [ -s "${out}" ] && jq -e . "${out}" >/dev/null 2>&1; then
    jq . "${out}"
  else
    cat "${out}"; echo
  fi
  rm -f "${out}"
  case "${status}" in 2??) return 0 ;; *) return 1 ;; esac
}

# gw_curl <method> <path> [extra curl args...]
gw_curl() {
  local method="$1"; shift
  local path="$1"; shift
  ensure_gateway_portforward
  local out status
  out=$(mktemp)
  status=$(curl -sS -o "${out}" -w "%{http_code}" -X "${method}" \
    "${GATEWAY_URL}${path}" "$@" 2>/dev/null || echo "000")
  echo -e "${CYAN}# HTTP ${status}${NC}"
  if command -v jq >/dev/null && [ -s "${out}" ] && jq -e . "${out}" >/dev/null 2>&1; then
    jq . "${out}"
  else
    cat "${out}"; echo
  fi
  rm -f "${out}"
  case "${status}" in 2??) return 0 ;; *) return 1 ;; esac
}

# MCP streamable responses can be either plain JSON or SSE (`data: {...}`).
# Return the first JSON object either way.
mcp_first_json() {
  local f="$1"
  grep -m1 '^{' "${f}" 2>/dev/null \
    || sed -n 's/^data: //p' "${f}" | head -n1
}

# mcp_init_session <url> [extra curl args...] — establish an MCP session:
#   ① POST initialize (retried; a freshly-applied backend/route can 500 for a
#      few seconds until xDS programs it and the upstream MCP server is reachable)
#   ② POST notifications/initialized (required by the MCP spec)
# Echoes the Mcp-Session-Id on success; returns non-zero if none appears.
mcp_init_session() {
  local url="$1"; shift
  local accept="application/json, text/event-stream" sid hdr
  hdr=$(mktemp)
  for _ in $(seq 1 20); do
    curl -sS -D "${hdr}" -o /dev/null -X POST "${url}" "$@" \
      -H "Accept: ${accept}" -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo-curl","version":"1.0"}}}' 2>/dev/null
    sid=$(awk -v IGNORECASE=1 -F': ' 'tolower($1)=="mcp-session-id"{gsub(/\r/,"",$2);print $2;exit}' "${hdr}")
    [ -n "${sid}" ] && break
    sleep 2
  done
  rm -f "${hdr}"
  [ -z "${sid}" ] && return 1
  curl -sS -o /dev/null -X POST "${url}" "$@" \
    -H "Accept: ${accept}" -H "Content-Type: application/json" -H "Mcp-Session-Id: ${sid}" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' 2>/dev/null || true
  echo "${sid}"
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
  # bat (https://github.com/sharkdp/bat) gives syntax-highlighted output
  # with line numbers — much easier to follow during a live demo than raw
  # cat. Fall back to cat when bat isn't installed (CI containers etc).
  # On Debian/Ubuntu the binary is sometimes 'batcat' instead of 'bat'.
  local bat_bin=""
  if command -v bat >/dev/null 2>&1; then bat_bin=bat
  elif command -v batcat >/dev/null 2>&1; then bat_bin=batcat
  fi
  if [ -n "${bat_bin}" ]; then
    "${bat_bin}" --style=numbers --paging=never --color=always \
      --language=yaml "${f}"
  else
    cat "${f}"
  fi
  echo -e "${CYAN}--- end ---${NC}"
}

# say_prompt: echo a user prompt in a recognizable banner so the
# audience sees what the request is asking the LLM. Used by demos
# where the prompt content is part of the narrative (prompt-guard,
# prompt enrichment, transformations, etc.) — not for trivial 'hi'
# prompts where seeing the text adds no info.
say_prompt() {
  local prompt="$1"
  echo -e "${CYAN}user prompt →${NC} ${prompt}"
}

# Substitute only the known Keycloak vars into a manifest, leaving every other
# `$` literal. Prefers envsubst; falls back to sed when gettext isn't on PATH
# (common on stock macOS) so applies never silently break.
_render_manifest() {
  if command -v envsubst >/dev/null 2>&1; then
    envsubst '${KEYCLOAK_ISSUER} ${KEYCLOAK_JWKS_URL} ${KEYCLOAK_REALM} ${KEYCLOAK_EXTERNAL_HOST}' < "$1"
  else
    sed -e "s|\${KEYCLOAK_ISSUER}|${KEYCLOAK_ISSUER}|g" \
        -e "s|\${KEYCLOAK_JWKS_URL}|${KEYCLOAK_JWKS_URL}|g" \
        -e "s|\${KEYCLOAK_REALM}|${KEYCLOAK_REALM}|g" \
        -e "s|\${KEYCLOAK_EXTERNAL_HOST}|${KEYCLOAK_EXTERNAL_HOST:-}|g" "$1"
  fi
}

apply_and_wait() {
  local f="$1"
  # Bail loudly on apply failure. Without this, `set -uo pipefail` (no
  # `-e`) lets the script keep running on a failed apply, and the
  # subsequent demo steps end up testing the WRONG state — e.g. an
  # RBAC demo that printed "HTTP 200" for a user that should have been
  # 403, because the manifest with the typo never landed.
  # Render ${KEYCLOAK_ISSUER}/${KEYCLOAK_JWKS_URL} (and nothing else — the
  # explicit var list leaves any other literal `$` in manifests untouched, so
  # CEL expressions etc. are safe) so policy-jwt.yaml picks up the live issuer.
  if ! _render_manifest "${f}" \
        | kubectl --context "${CLUSTER_CONTEXT}" apply -f -; then
    echo -e "${RED}ERROR: kubectl apply failed for ${f}${NC}" >&2
    echo -e "${RED}       The demo cannot continue meaningfully — exiting.${NC}" >&2
    exit 1
  fi
  sleep 3
}

delete_and_wait() {
  local f="$1"
  kubectl --context "${CLUSTER_CONTEXT}" delete -f "${f}" --ignore-not-found >/dev/null 2>&1 || true
  sleep 2
}

prompt_continue() {
  if [ "${DEMO_AUTO:-0}" = "1" ]; then return; fi
  local msg="${1:-Press Enter to continue}"
  read -r -p $'\n'"${msg}... " _
}
