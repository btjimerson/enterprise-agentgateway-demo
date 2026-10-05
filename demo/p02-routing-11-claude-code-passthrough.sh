#!/bin/bash
# Pillar 2 · Routing — Case 11: Claude Code passthrough + the model-header trick.
#
# What it shows
#   How to front Anthropic (Claude) with agentgateway so Claude Code can talk to
#   it, and how model selection behaves through the proxy. The backend pins NO
#   model (spec.ai.provider.anthropic: {}), so agentgateway PASSES THROUGH
#   whatever model the client sends — switch models in Claude Code and your
#   choice is honored. A pinned anthropic.model would OVERRIDE and reject
#   mismatches instead.
#
# Two auth modes (AUTH_MODE):
#   oauth  (default) — Claude subscription via SSO/OAuth (e.g. JumpCloud). No API
#                      key: the gateway PASSES THROUGH the OAuth token Claude Code
#                      obtained at login. Applies backend-anthropic-oauth.yaml +
#                      policy-claude-buffer.yaml (the OAuth flow needs a 10MB
#                      buffer). The curl header-trick is skipped (no token to
#                      send from a script); proof is via Claude Code + proxy logs.
#   apikey           — Anthropic API key. Applies backend-anthropic-apikey.yaml,
#                      creates the anthropic-secret from $ANTHROPIC_API_KEY (the
#                      gateway injects it as x-api-key), and runs the full curl
#                      header-trick (x-requested-model / x-actual-model).
#
# The model-header trick echoes the requested vs. actual model as response
# headers. It parses the response BODY, so it works for NON-streaming curls;
# Claude Code STREAMS, so for real Claude Code traffic read the model from the
# proxy logs (gen_ai.request.model=...).
#
# Prereqs
#   - The agentgateway control plane + agentgateway-proxy (install scripts).
#   - AUTH_MODE=apikey only: ANTHROPIC_API_KEY in your .envrc (see .envrc.sample).
#
# Usage:  [AUTH_MODE=oauth|apikey] [DEMO_KEEP=1] ./p02-routing-11-claude-code-passthrough.sh
# Docs: https://docs.solo.io/agentgateway/latest/integrations/llm-clients/claude-code/
#
# Author: Brian Jimerson

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

MANIFESTS="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
ROUTE="${MANIFESTS}/httproute-claude.yaml"
MODEL_POLICY="${MANIFESTS}/policy-claude-model-headers.yaml"
BACKEND_APIKEY="${MANIFESTS}/backend-anthropic-apikey.yaml"
BACKEND_OAUTH="${MANIFESTS}/backend-anthropic-oauth.yaml"
BUFFER_POLICY="${MANIFESTS}/policy-claude-buffer.yaml"
NS="${AGENTGATEWAY_NAMESPACE}"
SECRET_NAME=anthropic-secret

AUTH_MODE="${AUTH_MODE:-oauth}"
case "${AUTH_MODE}" in oauth|apikey) ;; *) echo "AUTH_MODE must be 'oauth' or 'apikey'" >&2; exit 1 ;; esac

# Two real Anthropic model IDs to switch between.
MODEL_A="claude-haiku-4-5-20251001"
MODEL_B="claude-sonnet-4-5-20250929"

cleanup() {
  if [ "${DEMO_KEEP:-0}" = "1" ]; then
    demo_step "Cleanup — DEMO_KEEP=1: leaving the anthropic backend, /claude route, and policies in place"
    echo -e "${CYAN}  Claude Code can keep using ANTHROPIC_BASE_URL. Remove later with:${NC}"
    echo    "  kubectl -n ${NS} delete -f ${MODEL_POLICY} -f ${ROUTE} ${AUTH_MODE_MANIFESTS:-}"
    [ "${AUTH_MODE}" = "apikey" ] && echo "  kubectl -n ${NS} delete secret ${SECRET_NAME}"
    return
  fi
  demo_step "Cleanup — removing the /claude route, backend, and policies"
  delete_and_wait "${MODEL_POLICY}"
  [ "${AUTH_MODE}" = "oauth" ] && delete_and_wait "${BUFFER_POLICY}"
  delete_and_wait "${ROUTE}"
  delete_and_wait "${BACKEND_APIKEY}"
  delete_and_wait "${BACKEND_OAUTH}"
  kubectl --context "${CLUSTER_CONTEXT}" -n "${NS}" delete secret "${SECRET_NAME}" \
    --ignore-not-found >/dev/null 2>&1 || true
}
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 2 · Routing — Claude Code passthrough + model-header trick  (AUTH_MODE=${AUTH_MODE})"

if [ "${AUTH_MODE}" = "apikey" ]; then
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo -e "${RED}ERROR: AUTH_MODE=apikey needs ANTHROPIC_API_KEY in your .envrc (see .envrc.sample).${NC}" >&2
    exit 1
  fi
  demo_step "Create the anthropic-secret — the gateway injects it as x-api-key upstream"
  kubectl --context "${CLUSTER_CONTEXT}" -n "${NS}" create secret generic "${SECRET_NAME}" \
    --from-literal=Authorization="${ANTHROPIC_API_KEY}" \
    --dry-run=client -o yaml | kubectl --context "${CLUSTER_CONTEXT}" apply -f - >/dev/null
  echo -e "${GREEN}  secret/${SECRET_NAME} ready (clients never send the real key)${NC}"
  BACKEND="${BACKEND_APIKEY}"
else
  demo_step "Subscription/OAuth mode — no API key; the gateway passes your Claude Code OAuth token through"
  echo -e "${CYAN}  Sign-in (e.g. JumpCloud SSO) happens in Claude Code; the gateway only forwards${NC}"
  echo -e "${CYAN}  the resulting token. It also applies a 10MB body buffer the OAuth flow needs.${NC}"
  BACKEND="${BACKEND_OAUTH}"
fi

demo_step "The passthrough backend — NO model pinned (spec.ai.provider.anthropic: {})"
show_file "${BACKEND}"
echo -e "${CYAN}  Empty {} = the client's model is forwarded as-is. A pinned model would${NC}"
echo -e "${CYAN}  OVERRIDE the client and reject mismatches — the switch would not be honored.${NC}"
prompt_continue "Apply the backend, the /claude route, and policies"
apply_and_wait "${BACKEND}"
[ "${AUTH_MODE}" = "oauth" ] && apply_and_wait "${BUFFER_POLICY}"
apply_and_wait "${ROUTE}"
apply_and_wait "${MODEL_POLICY}"

# send_model <model> — POST /claude/v1/messages and show requested vs actual model.
send_model() {
  local model="$1" h b code req act
  ensure_gateway_portforward
  h=$(mktemp); b=$(mktemp)
  code=$(curl -sS -o "${b}" -D "${h}" -w '%{http_code}' \
    -X POST "${GATEWAY_URL}/claude/v1/messages" \
    -H 'content-type: application/json' \
    -H 'anthropic-version: 2023-06-01' \
    -d "{\"model\":\"${model}\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in three words.\"}]}" \
    2>/dev/null)
  req=$(awk -v IGNORECASE=1 -F': ' 'tolower($1)=="x-requested-model"{gsub(/\r/,"");print $2}' "${h}")
  act=$(awk -v IGNORECASE=1 -F': ' 'tolower($1)=="x-actual-model"{gsub(/\r/,"");print $2}' "${h}")
  echo -e "  requested model : ${CYAN}${model}${NC}    (HTTP ${code})"
  echo -e "  ${YELLOW}x-requested-model:${NC} ${req:-<none>}"
  echo -e "  ${YELLOW}x-actual-model:   ${NC} ${act:-<none>}"
  rm -f "${h}" "${b}"
}

if [ "${AUTH_MODE}" = "apikey" ]; then
  demo_step "The model-header trick — prove Anthropic uses the model the client asked for"
  show_file "${MODEL_POLICY}"
  send_model "${MODEL_A}"
  prompt_continue "Now switch the model — the headers should track it (passthrough)"
  send_model "${MODEL_B}"
else
  demo_step "In OAuth mode the header-trick curl is skipped (a script has no OAuth token)"
  echo -e "${CYAN}  The model-header policy is applied anyway (works for non-streaming curls with a token).${NC}"
  echo -e "${CYAN}  Prove passthrough with the proxy logs below once you drive traffic from Claude Code.${NC}"
fi

demo_step "Model proof in the proxy logs — this is how you see it for STREAMING clients (Claude Code)"
echo -e "${CYAN}  kubectl -n ${NS} logs deploy/agentgateway-proxy | grep gen_ai.request.model${NC}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${NS}" logs deploy/agentgateway-proxy --tail=50 2>/dev/null \
  | grep -F 'route=agentgateway-system/claude' \
  | grep -oE 'gen_ai.request.model=[^ ]+' | tail -4 | sed 's/^/  /'

demo_step "Point Claude Code at agentgateway"
GW_IP="$(kubectl --context "${CLUSTER_CONTEXT}" -n "${NS}" get svc agentgateway-proxy \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
echo -e "${CYAN}  # Via a port-forward:${NC}"
echo    "  kubectl -n ${NS} port-forward svc/agentgateway-proxy 8080:8080 &"
echo    "  export ANTHROPIC_BASE_URL=\"http://localhost:8080/claude\""
echo -e "${CYAN}  # …or via the gateway LoadBalancer (port 8080):${NC}"
echo    "  export ANTHROPIC_BASE_URL=\"http://${GW_IP:-<gateway-ip>}:8080/claude\""
if [ "${AUTH_MODE}" = "apikey" ]; then
  echo    "  export ANTHROPIC_API_KEY=\"placeholder\"   # any non-empty value; the gateway injects the real key"
else
  echo -e "${GREEN}  # Do NOT set ANTHROPIC_API_KEY — sign in normally (JumpCloud SSO); Claude Code's${NC}"
  echo -e "${GREEN}  # OAuth token is passed through by the gateway.${NC}"
fi
echo    "  claude   # start Claude Code — all traffic now flows through agentgateway"
echo ""
echo -e "${CYAN}  Switch models in Claude Code (/model) and watch them appear here:${NC}"
echo    "  kubectl -n ${NS} logs -f deploy/agentgateway-proxy | grep gen_ai.request.model"
echo ""
echo -e "${YELLOW}  To keep this wired up for Claude Code after the demo, re-run with DEMO_KEEP=1.${NC}"

prompt_continue "Demo complete — press Enter to clean up"
