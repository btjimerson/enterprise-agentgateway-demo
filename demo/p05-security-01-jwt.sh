#!/bin/bash
# Pillar 5 · Case 1: JWT authentication.
#
# ─────────────────────────────────────────────────────────────────────
# WHY THIS PATTERN
# ─────────────────────────────────────────────────────────────────────
# The gateway should NEVER accept anonymous calls in production —
# every request needs to be tied to a verifiable identity so policies
# (rate-limit, RBAC, audit) have something to key off. JWT is the
# standard answer: a token signed by a trusted IDP, presented as a
# Bearer header, validated cryptographically at the gateway.
#
# Common audience confusion: validators do NOT sign tokens. They
# fetch the IDP's public keys (JWKS) and use them to verify the
# signature on tokens the IDP signed. The gateway holds no secrets;
# revoking trust is just a matter of removing the issuer from the
# JWT policy.
#
# ─────────────────────────────────────────────────────────────────────
# FLOW DIAGRAM (printed at runtime)
# ─────────────────────────────────────────────────────────────────────
#
#   ┌────────┐                                     ┌──────────────┐
#   │ Client │  ① POST + no Authorization header   │  Gateway     │
#   │        │ ──────────────────────────────────▶ │  (JWT policy │
#   │        │ ◀── 401 "no bearer token found" ─── │   strict)    │
#   └────────┘                                     └──────────────┘
#
#   ┌────────┐  ② mint JWT (password grant)        ┌──────────────┐
#   │ Client │ ──────────────────────────────────▶ │   Keycloak   │
#   │        │ ◀── access_token (signed RS256) ─── │              │
#   └────────┘                                     └──────────────┘
#
#                       (gateway fetches Keycloak's public keys
#                        on first use, caches per cacheDuration)
#                                       │
#                       ┌───────────────▼─────────┐
#                       │  Keycloak  /certs       │
#                       │  (JWKS — public keys)   │
#                       └─────────────────────────┘
#
#   ┌────────┐  ③ POST + Authorization: Bearer …   ┌──────────────┐
#   │ Client │ ──────────────────────────────────▶ │  Gateway     │
#   │        │                                     │  ┌────────┐  │
#   │        │                                     │  │ verify │  │
#   │        │                                     │  │ sig +  │  │
#   │        │                                     │  │ exp +  │  │
#   │        │                                     │  │ iss    │  │
#   │        │                                     │  └────────┘  │
#   │        │ ◀── 200 + LLM response ──────────── │              │
#   └────────┘                                     └──────────────┘
#
# Steps in this script: ① is demo_step 3 (the anonymous request);
# ② happens inside get_jwt; ③ is demo_step 4 (with-bearer).
#
# Applies policy-jwt.yaml at the Gateway level so every request is
# required to carry a bearer token issued by the Keycloak agentgateway
# realm.
#   1. Anonymous POST to /chat → 401
#   2. Re-POST with a valid bearer → 200
# Reverts on exit.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

POLICY="${MANIFESTS_DIR}/policy-jwt.yaml"

cleanup() { delete_and_wait "${POLICY}"; }
trap 'cleanup; _cleanup_portforwards' EXIT

# print_jwt_overview: ASCII flow + key talking points. Heredoc with
# colors uses echo -e because heredocs don't interpret \033 escapes.
print_jwt_overview() {
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  How JWT validation works${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo "  The gateway does NOT sign tokens — only the IDP (Keycloak) does."
  echo "  The gateway pulls the IDP's public keys (JWKS) and uses them to"
  echo "  verify signatures on tokens the IDP signed. The gateway holds"
  echo -e "  no secrets; revoking trust = removing the issuer from ${YELLOW}policy-jwt${NC}."
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  Flow${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  cat <<'EOF'

  ┌────────┐  ① POST + no Authorization      ┌──────────────┐
  │ Client │ ─────────────────────────────▶ │   Gateway    │
  │        │ ◀── 401 "no bearer token" ──── │  (JWT strict)│
  └────────┘                                 └──────────────┘

  ┌────────┐  ② password grant               ┌──────────────┐
  │ Client │ ─────────────────────────────▶ │   Keycloak   │
  │        │ ◀── signed access_token ────── │              │
  └────────┘                                 └──────────────┘
                  (gateway fetches  ┌──────────────────────┐
                   Keycloak public  │  Keycloak  /certs    │
                   keys on demand)  │  JWKS (public keys)  │
                                    └──────────────────────┘
  ┌────────┐  ③ POST + Authorization: Bearer ┌──────────────┐
  │ Client │ ─────────────────────────────▶ │   Gateway    │
  │        │                                 │  verify sig  │
  │        │                                 │  + exp + iss │
  │        │ ◀── 200 + LLM response ──────── │              │
  └────────┘                                 └──────────────┘

EOF
  echo -e "${CYAN}  Steps below: ${YELLOW}①${NC} = demo_step 3 (anonymous), ${YELLOW}②${NC} = inside"
  echo -e "${CYAN}  get_jwt, ${YELLOW}③${NC} = demo_step 4 (with-bearer).${NC}"
  echo ""
}

demo_header "Pillar 5 · Security — JWT Authentication"

print_jwt_overview
prompt_continue "Press Enter to start."

demo_step "1. Show the JWT policy"
show_file "${POLICY}"
prompt_continue

demo_step "2. Apply the policy"
apply_and_wait "${POLICY}"

ensure_gateway_portforward

USER_PROMPT="hi"
BODY=$(jq -n --arg p "${USER_PROMPT}" \
  '{model:"gpt-4o",messages:[{role:"user",content:$p}]}')

# Compact request/response printer: echoes the curl command (with the
# auth header obfuscated to a fingerprint), fires it, and shows
# HTTP code + a snippet of the response body. Lets the audience see
# the full transaction instead of just the status code.
fire() {
  local label="$1" auth_header="$2"
  echo -e "${CYAN}# ${label}${NC}"
  if [ -n "${auth_header}" ]; then
    local short="${auth_header:0:25}…"
    echo "  curl -X POST ${GATEWAY_URL}/chat/v1/chat/completions \\"
    echo "    -H 'Authorization: ${short}' \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    --data '${BODY}'"
  else
    echo "  curl -X POST ${GATEWAY_URL}/chat/v1/chat/completions \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    --data '${BODY}'"
  fi
  local out; out=$(mktemp)
  local args=(-sS -o "${out}" -w "%{http_code}" --max-time 10 -X POST
    "${GATEWAY_URL}/chat/v1/chat/completions"
    -H "Content-Type: application/json"
    -H "x-user-id: ${DEMO_USER_BOB}"
    --data "${BODY}")
  [ -n "${auth_header}" ] && args+=(-H "Authorization: ${auth_header}")
  local code; code=$(curl "${args[@]}")
  case "${code}" in
    2??) echo -e "  ${GREEN}→ HTTP ${code}${NC}" ;;
    *)   echo -e "  ${RED}→ HTTP ${code}${NC}" ;;
  esac
  if [ -s "${out}" ]; then
    if jq -e . "${out}" >/dev/null 2>&1; then
      jq '{model: (.model // null), content: (.choices[0].message.content // null), error: (.error // null)}' "${out}" 2>/dev/null \
        || head -c 200 "${out}"
    else
      head -c 200 "${out}"; echo
    fi
  fi
  rm -f "${out}"
}

demo_step "3. Anonymous request — no Authorization header (expect HTTP 401)"
say_prompt "${USER_PROMPT}"
fire "anonymous" ""
echo ""

demo_step "4. Mint a JWT from Keycloak and retry (expect HTTP 200)"
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")
echo -e "${CYAN}# Bearer JWT minted via Keycloak password grant. Decoded payload:${NC}"
jwt_decode "${TOKEN}" 2>/dev/null \
  | jq '{iss, sub, preferred_username, aud, exp}' 2>/dev/null \
  || echo "  (jwt_decode helper unavailable)"
echo ""
fire "with bearer" "Bearer ${TOKEN}"

echo ""
echo -e "${GREEN}Expected: first request 401, second request 200.${NC}"
echo -e "${YELLOW}Policy APPLIED. Inspect, then press Enter to revert.${NC}"
prompt_continue "Press Enter to tear down and exit"
