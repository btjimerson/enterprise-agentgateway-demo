#!/bin/bash
# Pillar 5 · Case 6: WAF — OWASP Core Rule Set on the /chat route.
#
# ─────────────────────────────────────────────────────────────────────
# WHY THIS CASE
# ─────────────────────────────────────────────────────────────────────
# p05-security-02 (prompt guard) defends against AI-native abuse: PII
# leakage and prompt injection. It says nothing about the classic web
# attacks that ride the same HTTP request — SQLi, XSS, LFI, command
# injection. An LLM route is still an HTTP route, and `/chat` forwards
# a user-controlled string to something that may hold a tool, a shell,
# or a database connection.
#
# WAF is the layer that catches those, using the bundled OWASP Core
# Rule Set — thousands of maintained signatures, no rules of your own
# to write. The two controls are complementary, not alternatives:
# prompt guard reads INTENT, the WAF reads PAYLOAD.
#
# ─────────────────────────────────────────────────────────────────────
# THE ONE SETTING THAT MATTERS
# ─────────────────────────────────────────────────────────────────────
# WAFPolicy.spec.processingConfig.request.mode defaults to `Headers`,
# so the WAF never sees the request BODY. On an API gateway that is
# mostly fine — attacks arrive in the URI. On an AGENT gateway the
# payload IS the body: the attack is a string inside a JSON prompt.
# With the default, every body-borne attack sails through and the WAF
# looks like it is working, because URI attacks still get blocked.
#
# This demo shows that gap explicitly in step ③ before closing it.
#
# ─────────────────────────────────────────────────────────────────────
# FLOW
# ─────────────────────────────────────────────────────────────────────
#
#   ① Baseline, no WAF     SQLi inside a prompt   → 200, reaches model
#   ② Apply WAFPolicy only  same request          → 200, still! (dormant)
#   ③ Apply the binding     same request          → 403
#   ④ Probe matrix          benign / SQLi / XSS / LFI / custom UA rule
#
# Step ② is not filler: a WAFPolicy has no targetRefs and does nothing
# until an EnterpriseAgentgatewayPolicy references it. That is the most
# common way to think WAF is on when it is not.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

POLICY="${MANIFESTS_DIR}/waf/wafpolicy-owasp-crs.yaml"
BINDING="${MANIFESTS_DIR}/waf/agentgatewaypolicy-waf-binding.yaml"

cleanup() {
  delete_and_wait "${BINDING}"
  delete_and_wait "${POLICY}"
}
trap 'cleanup; _cleanup_portforwards' EXIT

# Attack payloads, defined once so the same string is provably reused
# across the baseline and the post-policy probe.
SQLI_PROMPT='1 UNION SELECT * FROM users--'
XSS_PROMPT='<script>alert(1)</script>'

# COMPACT JSON, deliberately — `jq -c`, not `jq -n`.
#
# Attaching ANY WAFPolicy makes the gateway reject a request whose body
# contains a NEWLINE with 403, even a single trailing one. Verified on a
# live cluster: with no WAFPolicy attached a pretty-printed
# body returns 200; with one attached it returns 403 regardless of
# processingConfig.request.mode and regardless of whether coreRuleSet is
# set at all. So it is not a CRS signature — it is the WAF integration.
#
# Pretty-printing here would make every probe below return 403, including
# the benign one, and the demo would look like it worked.
chat_body() {
  jq -cn --arg p "$1" '{model:"gpt-4o",messages:[{role:"user",content:$p}]}'
}

# Fire one request and report the status against what we expect.
# $1 label   $2 expected code   $3.. curl args
fire() {
  local label="$1" expect="$2"; shift 2
  local code
  code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 "$@" 2>/dev/null || echo "000")
  printf "  %-34s " "${label}"
  if [ "${code}" = "${expect}" ]; then
    echo -e "${GREEN}→ HTTP ${code}${NC}"
  else
    echo -e "${RED}→ HTTP ${code} (expected ${expect})${NC}"
  fi
}

post_prompt() {
  local label="$1" expect="$2" prompt="$3"
  fire "${label}" "${expect}" \
    -X POST "${GATEWAY_URL}/chat/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$(chat_body "${prompt}")"
}

demo_header "Pillar 5 · Security — WAF (OWASP Core Rule Set) on /chat"

echo ""
echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
echo -e "${CYAN}  Prompt guard vs WAF${NC}"
echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
echo "  p05-security-02 blocks PII and prompt injection — AI-native abuse."
echo "  The WAF blocks the classic web attacks riding the same request:"
echo "  SQLi, XSS, LFI, command injection. Prompt guard reads INTENT;"
echo "  the WAF reads PAYLOAD. You want both."
echo ""
echo -e "  ${YELLOW}The WAF server is already running${NC} — the enterprise-agentgateway"
echo "  chart ships it for this GatewayClass. No install step is needed:"
echo "    kubectl -n ${AGENTGATEWAY_NAMESPACE} get deploy waf-server-enterprise-agentgateway"
echo ""
prompt_continue "Press Enter to start."

ensure_gateway_portforward

demo_step "① Baseline — no WAF. Send a SQL-injection payload inside a prompt"
say_prompt "${SQLI_PROMPT}"
post_prompt "SQLi in prompt (no WAF)" "200" "${SQLI_PROMPT}"
echo ""
echo -e "  ${YELLOW}200 — the gateway forwarded it to the model verbatim.${NC}"
prompt_continue

demo_step "② Apply the WAFPolicy ALONE — and watch nothing change"
show_file "${POLICY}"
prompt_continue
apply_and_wait "${POLICY}"
post_prompt "SQLi in prompt (policy only)" "200" "${SQLI_PROMPT}"
echo ""
echo -e "  ${YELLOW}Still 200. A WAFPolicy has no targetRefs — it is DORMANT until${NC}"
echo -e "  ${YELLOW}something references it. This is the most common way to believe${NC}"
echo -e "  ${YELLOW}the WAF is on when it is not.${NC}"
prompt_continue

demo_step "③ Apply the binding — EnterpriseAgentgatewayPolicy.spec.traffic.entWAF"
show_file "${BINDING}"
prompt_continue
apply_and_wait "${BINDING}"
echo -e "  Attachment status:"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  get enterpriseagentgatewaypolicy chat-waf-binding \
  -o jsonpath='{range .status.ancestors[0].conditions[*]}    {.type}={.status} ({.reason}){"\n"}{end}' 2>/dev/null
echo ""
post_prompt "SQLi in prompt (bound)" "403" "${SQLI_PROMPT}"
echo ""
echo -e "  ${GREEN}403 — CRS rule 942xxx matched the body and rejected it before${NC}"
echo -e "  ${GREEN}the request ever reached a model. No tokens were spent.${NC}"
prompt_continue

demo_step "④ Probe matrix — what the same policy catches"
post_prompt "benign prompt"                "200" "What is the capital of France?"
post_prompt "SQLi in prompt (body)"        "403" "${SQLI_PROMPT}"
post_prompt "XSS in prompt (body)"         "403" "${XSS_PROMPT}"
fire "LFI probe in URI"                    "403" "${GATEWAY_URL}/chat/.htaccess"
fire "custom rule: scammer User-Agent"     "403" \
  -X POST "${GATEWAY_URL}/chat/v1/chat/completions" \
  -H "Content-Type: application/json" -H "User-Agent: scammer-bot" \
  -d "$(chat_body 'hello')"

echo ""
echo -e "${GREEN}─────────────────────────────────────────────────────────────────${NC}"
echo -e "${GREEN}  What just happened${NC}"
echo -e "${GREEN}─────────────────────────────────────────────────────────────────${NC}"
echo -e "  - One bundled rule set covered SQLi, XSS and LFI across both the"
echo -e "    URI (phase 1) and the JSON prompt body (phase 2). The CRS authors"
echo -e "    maintain the signatures; you track waf-server versions."
echo -e "  - ${YELLOW}processingConfig.request.mode: HeadersAndBody${NC} is what made the"
echo -e "    body cases work. The default is Headers, under which the three"
echo -e "    body probes above all return 200 — a WAF that looks healthy and"
echo -e "    misses the attack surface that matters most on an agent gateway."
echo -e "  - customDirectives is the extension point for your own rules; the"
echo -e "    User-Agent rule (id 1001) rides alongside the bundled CRS."
echo -e "  - The benign prompt still returns 200, so this is not a blunt"
echo -e "    instrument — it is a signature match, not a heuristic."
echo ""
echo -e "  ${YELLOW}Caveat worth saying out loud if asked:${NC} with a WAFPolicy attached,"
echo -e "  a request body containing a NEWLINE is rejected 403 no matter what"
echo -e "  the rules say. Real OpenAI SDK clients send compact JSON, so this"
echo -e "  does not bite in practice — but a hand-written pretty-printed curl"
echo -e "  will look like a false positive."
echo ""
prompt_continue "Press Enter to remove the WAFPolicy + binding"
