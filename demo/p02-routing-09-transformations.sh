#!/bin/bash
# Pillar 2 · Case 9: response header modification.
#
# ─────────────────────────────────────────────────────────────────────
# WHY THIS PATTERN
# ─────────────────────────────────────────────────────────────────────
# The gateway sits IN-LINE with every LLM request, so it can rewrite
# the response on the way back without the app or the LLM provider
# knowing. Header hygiene is the everyday case:
#
#   - Strip provider-specific identifiers from the response
#     (x-request-id leaks OpenAI's internal request ID).
#   - Add gateway-owned identity headers (x-served-by) so clients know
#     which gateway served them.
#
# Both are things platform teams otherwise have to do in every app.
#
# ─────────────────────────────────────────────────────────────────────
# FLOW DIAGRAM
# ─────────────────────────────────────────────────────────────────────
#
#                   ┌────────────────────────────────────────┐
#                   │  Gateway with chat-transformations     │
#   ┌────────┐      │                                        │       ┌─────────┐
#   │ Client │ ───▶ │  request passes through unchanged      │ ───▶ │ OpenAI  │
#   └────────┘      │                                        │       └─────────┘
#                   │  RESPONSE transform                    │            │
#                   │   traffic.headerModifiers.response     │            │
#                   │   - add x-served-by: enterprise-agw    │            │
#                   │   - remove x-request-id (upstream)     │            ▼
#                   │                                        │  upstream returns
#                   │ ◀──────────────────────────────────────│  response w/ headers
#                   └────────────────────────────────────────┘
#                                        │
#                                        ▼
#                          Client receives:
#                            x-served-by: enterprise-agw  (added)
#                            <no x-request-id>            (stripped)
#
# The note that always comes up in audience questions:
#
#   - `traffic.headerModifiers` vs `traffic.transformation`:
#     `transformation` is for HTTP routes; `headerModifiers` is the
#     Gateway-API-style filter that runs on the LLM-protocol path. We
#     use headerModifiers here because /chat goes through the AI-aware
#     backend, not the plain HTTP path.
#
# This step used to also force temperature=0 and claim the response was
# therefore deterministic. It isn't — temperature 0 is greedy decoding, not
# determinism, and identical calls still return different completions. Removed
# elsewhere; body rewriting is covered by p08-modelcontrols-01-tool-disable.sh.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

POLICY="${MANIFESTS_DIR}/policy-transformation.yaml"

cleanup() { delete_and_wait "${POLICY}"; }
trap 'cleanup; _cleanup_portforwards' EXIT

print_xform_overview() {
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  Why response header modification${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo "  The gateway sits in-line with every LLM call, so it can rewrite"
  echo "  the response on the way back without the app or LLM provider"
  echo "  knowing. This demo:"
  echo -e "    - ${YELLOW}strips${NC} the provider-specific x-request-id, so OpenAI's"
  echo "      internal request ID never reaches the client."
  echo -e "    - ${YELLOW}adds${NC} a gateway-owned x-served-by header."
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  Flow${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  cat <<'EOF'

                ┌────────────────────────────────────────┐
                │  Gateway (chat-transformations)        │
  ┌────────┐    │                                        │   ┌─────────┐
  │ Client │ ─▶ │  request passes through unchanged      │ ─▶│ OpenAI  │
  └────────┘    │                                        │   └─────────┘
                │  RESPONSE transform                    │        │
                │   traffic.headerModifiers.response     │        │
                │   - add x-served-by                    │        │
                │   - remove x-request-id (upstream)     │        ▼
                │ ◀──────────────────────────────────────│  upstream reply
                └────────────────────────────────────────┘

  Client receives:
    x-served-by: enterprise-agw  (added)
    <no x-request-id>            (stripped)

EOF
  echo -e "${CYAN}  The FAQ the audience always asks:${NC}"
  echo -e "    - We use ${YELLOW}headerModifiers${NC} (Gateway-API filter) on the AI path,"
  echo -e "      not ${YELLOW}transformation${NC} which only runs on the plain HTTP path."
  echo ""
}

demo_header "Pillar 2 · LLM Routing — Request / Response Transformations"

print_xform_overview
prompt_continue "Press Enter to start."

demo_step "1. Show the transformation policy"
show_file "${POLICY}"
prompt_continue

demo_step "2. Apply the policy"
apply_and_wait "${POLICY}"

ensure_gateway_portforward
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")

demo_step "3. Send a request and inspect the RESPONSE headers"
USER_PROMPT="In one short sentence, what is an AI gateway?"
say_prompt "${USER_PROMPT}"
BODY=$(jq -n --arg p "${USER_PROMPT}" \
  '{model:"gpt-4o",messages:[{role:"user",content:$p}]}')

echo -e "${CYAN}# Response headers — looking for x-served-by added, x-request-id stripped:${NC}"
HDRS=$(mktemp)
curl -sS -D "${HDRS}" -o /tmp/xform.json --max-time 10 -X POST \
  "${GATEWAY_URL}/chat/v1/chat/completions" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "x-user-id: ${DEMO_USER_BOB}" \
  -H "Content-Type: application/json" \
  -d "${BODY}" >/dev/null
# Status line + just the two headers we care about — keeps the demo
# focused regardless of how many headers OpenAI returns.
head -1 "${HDRS}"
if grep -i '^x-served-by:' "${HDRS}" >/dev/null; then
  grep -i '^x-served-by:' "${HDRS}"
else
  echo -e "${YELLOW}  (x-served-by NOT present — policy may not have attached)${NC}"
fi
# The upstream really does send x-request-id — verified by making the same
# request with this policy absent, where the header is present. So its absence
# here is proof the policy stripped it, not proof that there was nothing to
# strip. Don't weaken this back to "or not sent by upstream".
if grep -i '^x-request-id:' "${HDRS}" >/dev/null; then
  echo -e "${YELLOW}  x-request-id leaked — policy didn't strip it:${NC}"
  grep -i '^x-request-id:' "${HDRS}"
else
  echo -e "${GREEN}  x-request-id stripped (OpenAI sends it; without this policy it${NC}"
  echo -e "${GREEN}  reaches the client — try it with the policy deleted).${NC}"
fi
rm -f "${HDRS}"
echo ""
echo -e "${CYAN}# Response body:${NC}"
jq '{model, content: .choices[0].message.content}' /tmp/xform.json 2>/dev/null \
  || cat /tmp/xform.json
rm -f /tmp/xform.json

echo ""
echo -e "${GREEN}The gateway owns the response envelope: it added a header of its own and${NC}"
echo -e "${GREEN}removed the provider's, with no change to the app or the backend.${NC}"
echo -e "${YELLOW}Policy APPLIED. Press Enter to revert.${NC}"
prompt_continue "Press Enter to tear down and exit"
