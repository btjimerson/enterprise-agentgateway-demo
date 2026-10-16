#!/bin/bash
# Pillar 2 · Case 8: per-user TOKEN rate limit.
#
# ─────────────────────────────────────────────────────────────────────
# WHY THIS PATTERN
# ─────────────────────────────────────────────────────────────────────
# Requests/min is abuse defense. It says nothing about cost, because one
# request can be 50 tokens or 50,000. A TOKEN rate limit caps the actual
# spend RATE, so a runaway agent can't burn a month of budget in sixty
# seconds.
#
# This is a RateLimitConfig — the same machinery as p02-routing-03,
# counting a different thing. Note `requestsPerUnit` is still the field
# name; with limitType: TOKEN that value is a token allowance, not a
# request count.
#
# IMPORTANT: it must use the setDescriptors form, NOT the simple
# descriptors form the published example uses. The simple form is
# accepted (state=ACCEPTED, policy Attached=True) and then silently
# enforces nothing. Full detail in ratelimitconfig-token-rate.yaml.
#
# ─────────────────────────────────────────────────────────────────────
# HOW THIS DIFFERS FROM CASE 2.10 (EnterpriseAgentgatewayBudget)
# ─────────────────────────────────────────────────────────────────────
# The docs treat these as complementary, not competing:
#
#   Case 2.8 (this)  short window   tokens/min, descriptors you write
#                    "not more than 300 tokens in the next minute"
#
#   Case 2.10        long window    USD or tokens over Day..Year, keyed by
#                    team/user/API key, declarative CRD
#                    "this team gets $5/day"
#
# Reach for a budget to express spend policy; reach for a token rate limit
# to stop a burst. This case used to be requests/min relabelled as a
# "budget", which duplicated 2.10's story while demonstrating neither.
#
# ─────────────────────────────────────────────────────────────────────
# FLOW
# ─────────────────────────────────────────────────────────────────────
#
#   POST /token-rate  (x-user-id: bob)
#         │
#         ▼
#   ┌──────────────────────────────────────────┐
#   │ token-rate-limit policy                  │
#   │   per-user-tokens-per-min: 300 tok/min   │
#   │   keyed on x-user-id, limitType: TOKEN   │
#   └──────────────────────────────────────────┘
#         │
#   req 1  ~400 tokens → 200   (debit 400, over the 300 allowance)
#   req 2            → 429     (allowance already exhausted)
#   req 3            → 429     (still exhausted this minute)
#
# The debit lands AFTER the response completes, so the request that crosses
# the limit still succeeds and the NEXT one is rejected — same boundary
# behavior as budgets. That's why req 1 gets a 200 even though it alone
# spends more than the entire allowance.
#
# The window is a FIXED wall-clock minute, not sliding — the counter resets
# at :00. The limit is deliberately small enough that ONE request exhausts
# it, and the script waits for a fresh minute when there isn't enough
# headroom left, so a run can't straddle a reset. The manifest has the
# measurements behind that.
#
# This demo owns its own /token-rate route. It previously attached to /chat,
# which p02-routing-03 also targets, and two entRateLimit policies on one
# route collide — so it had to `kubectl delete` the other demo's policy on
# startup. That hack is gone.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"
: "${AGENTGATEWAY_NAMESPACE:=agentgateway-system}"

ROUTE="${MANIFESTS_DIR}/httproute-token-rate.yaml"
CONFIG="${MANIFESTS_DIR}/ratelimitconfig-token-rate.yaml"
POLICY="${MANIFESTS_DIR}/policy-token-rate.yaml"

PROMPT='{"model":"gpt-4o","messages":[{"role":"user","content":"Explain Kubernetes in detail, about 300 words."}]}'

cleanup() {
  delete_and_wait "${POLICY}" || true
  delete_and_wait "${CONFIG}" || true
  delete_and_wait "${ROUTE}"  || true
}
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 2 · LLM Routing — Per-User Token Rate Limit (300 tokens/min)"

echo ""
echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
echo -e "${CYAN}  Tokens, not requests${NC}"
echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
echo "  Requests/min is abuse defense — it says nothing about cost, because"
echo "  one request can be 50 tokens or 50,000. A TOKEN rate limit caps the"
echo "  spend RATE, so a runaway agent can't burn a month of budget in a"
echo "  minute."
echo ""
echo -e "  ${YELLOW}limitType: TOKEN${NC} on the RateLimitConfig is the whole trick — same"
echo -e "  machinery as case 2.3, counting a different thing. (It needs the"
echo -e "  ${YELLOW}setDescriptors${NC} form; the simple descriptors form silently no-ops.)"
echo ""
echo -e "  ${CYAN}vs case 2.10:${NC} budgets are USD/tokens over Day..Year windows for"
echo -e "  spend policy. This is tokens/min for burst control. Complementary."
echo ""
prompt_continue "Press Enter to start."

demo_step "1. Show the route, the TOKEN RateLimitConfig, and the attaching policy"
show_file "${ROUTE}"
show_file "${CONFIG}"
show_file "${POLICY}"
prompt_continue

demo_step "2. Apply all three"
apply_and_wait "${ROUTE}"
apply_and_wait "${CONFIG}"
apply_and_wait "${POLICY}"

# Wait for the policy to report Attached AND the rate-limit config ACCEPTED.
# Without this, fast first-out requests race the config push to the proxy and
# pass through unfiltered.
echo "  waiting up to 30s for policy attachment + config acceptance..."
for _ in $(seq 1 30); do
  attached=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    get enterpriseagentgatewaypolicy token-rate-limit \
    -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Attached")].status}' \
    2>/dev/null)
  accepted=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    get ratelimitconfig per-user-tokens-per-min \
    -o jsonpath='{.status.state}' 2>/dev/null)
  if [ "${attached}" = "True" ] && [ "${accepted}" = "ACCEPTED" ]; then
    echo "  policy Attached=True, ratelimitconfig state=ACCEPTED."
    break
  fi
  sleep 1
done
# ratelimitconfig state=ACCEPTED and policy Attached=True are BOTH reported
# before the proxy actually has the snapshot, so they are not a sufficient gate.
# Firing too early gets every request through unfiltered and the demo looks
# broken. Measured: ~2s is far too short, ~25s is reliable.
SETTLE="${TOKEN_RATE_SETTLE:-30}"
echo "  waiting ${SETTLE}s for the proxy to pick up the rate-limit snapshot"
echo "  (ACCEPTED/Attached are reported before enforcement is actually live)"
sleep "${SETTLE}"

# The rate-limit window is a FIXED wall-clock minute — the counter resets at :00,
# it does not slide. Each request below is a real ~10s LLM call, so a run that
# starts late in a minute can have its requests split across two buckets, the
# counter reset in between, and no 429 ever appear. That is an intermittent
# false failure that depends purely on launch time.
#
# We need ~25s of headroom for the 2 requests that matter. If this minute has
# less than that left, wait for the next one.
NEED=25
LEFT=$((60 - $(date +%-S)))
if [ "${LEFT}" -lt "${NEED}" ]; then
  echo "  only ${LEFT}s left in this minute; waiting for a fresh window so the"
  echo "  token counter can't reset mid-run (fixed wall-clock buckets, not sliding)"
  sleep "${LEFT}"
fi

demo_step "3. Fire 3 requests as ${DEMO_USER_BOB} — 300 tokens/min, so req 1 exhausts it"
ensure_gateway_portforward
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")
declare -i ok=0 limited=0 errs=0 total=0
OUT=$(mktemp)
for i in $(seq 1 3); do
  code=$(curl -sS -o "${OUT}" -w "%{http_code}" --max-time 60 -X POST \
    "${GATEWAY_URL}/token-rate" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "x-user-id: ${DEMO_USER_BOB}" \
    -H "Content-Type: application/json" \
    -d "${PROMPT}")
  case "${code}" in
    200)
      ok=$((ok+1))
      toks=$(jq -r '.usage.total_tokens // 0' "${OUT}" 2>/dev/null)
      total=$((total + toks))
      printf "  request %d: ${GREEN}HTTP %s${NC}  tokens=%s  running total=%s / 300\n" \
        "$i" "$code" "${toks}" "${total}"
      ;;
    429)
      limited=$((limited+1))
      printf "  request %d: ${YELLOW}HTTP %s — token allowance exhausted${NC}\n" "$i" "$code"
      ;;
    *)
      errs=$((errs+1))
      printf "  request %d: ${RED}HTTP %s — %s${NC}\n" "$i" "$code" "$(head -c 80 "${OUT}")"
      ;;
  esac
done
rm -f "${OUT}"

echo ""
echo -e "${CYAN}# Tally${NC}"
echo -e "  200 (allowed):   ${ok}   — ${total} tokens spent"
echo -e "  429 (limited):   ${limited}"
echo -e "  errors:          ${errs}"
echo ""
if [ "${limited}" -gt 0 ] && [ "${ok}" -gt 0 ]; then
  echo -e "${GREEN}✓ Token rate limit enforced: ${ok} request(s) spent ${total} tokens, then 429${NC}"
  echo -e "${GREEN}  once the 300 tokens/min allowance was gone. Note the request that${NC}"
  echo -e "${GREEN}  crossed the limit still succeeded — the debit lands after the response.${NC}"
elif [ "${limited}" -eq 0 ]; then
  echo -e "${RED}✗ No 429. Likely causes:${NC}"
  echo -e "  - The per-minute window still holds credit from a previous run — the"
  echo -e "    counter is keyed by user, so wait 60s and re-run."
  echo -e "  - The config uses the SIMPLE descriptors form instead of setDescriptors."
  echo -e "    That form is accepted and enforces nothing. Check it still has"
  echo -e "    setDescriptors + limitType: TOKEN:"
  echo -e "    kubectl -n ${AGENTGATEWAY_NAMESPACE} get ratelimitconfig per-user-tokens-per-min -o yaml"
  echo -e "  - The rate-limiter pod is unhealthy."
  echo -e "    kubectl -n ${AGENTGATEWAY_NAMESPACE} get pods | grep rate-limiter"
else
  echo -e "${YELLOW}All requests 429'd — the allowance was already spent before this run.${NC}"
  echo -e "${YELLOW}Wait 60s for the per-minute window to reset and re-run.${NC}"
fi
echo -e "${YELLOW}Route + config + policy APPLIED. Press Enter to revert.${NC}"
prompt_continue "Press Enter to tear down and exit"
