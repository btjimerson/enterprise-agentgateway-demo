#!/bin/bash
# Pillar 2 · Case 2: LLM failover across priority groups.
#
# ─────────────────────────────────────────────────────────────────────
# WHY THIS PATTERN
# ─────────────────────────────────────────────────────────────────────
# An AI gateway in front of multiple LLM providers can paper over a
# provider outage without the app knowing. The pattern: rank providers
# in priority groups (group 0 = primary, group 1 = fallback), and
# define a HEALTH POLICY that auto-evicts a misbehaving provider for
# a configurable cooldown. The next request silently routes to the
# next group; once the cooldown expires, traffic shifts back.
#
# The state machine is the part audiences trip over: a single bad
# response doesn't change ROUTING for that same request — it FAILS
# OUT. The eviction starts AFTER. So the FIRST broken response is
# unavoidable; reqs 2+ feel the failover. That's what we'll see live.
#
# ─────────────────────────────────────────────────────────────────────
# FLOW DIAGRAM
# ─────────────────────────────────────────────────────────────────────
#
#   ┌────────┐  POST /chat   ┌──────────────────────────────────┐
#   │ Client │ ────────────▶ │  Gateway (multi-provider backend)│
#   └────────┘               │                                  │
#                            │  group 0  primary (broken)       │
#                            │  group 1  mock-llm fallback      │
#                            └──────────────────────────────────┘
#
#   req 1:  group 0 → primary returns HTTP 500
#                   ↓
#           policy-health-retry detects 5xx, EVICTS group 0 for cooldown
#                   ↓
#           Client sees: HTTP 500 (the bad response)
#
#   req 2:  group 0 is evicted → routes to group 1 (mock-llm)
#                   ↓
#           Client sees: HTTP 200 from mock-llm-1
#
#   req 3:  group 0 still evicted → group 1 again
#                   ↓
#           Client sees: HTTP 200 from mock-llm-1
#
#   (after cooldown: group 0 re-tested; if healthy, traffic returns)
#
# Applies policy-health-retry.yaml (evicts primary on any 5xx/429/401)
# AND swaps the multi-provider backend to one whose primary points at the
# mock-llm-broken provider (FAIL_ALL=1 → HTTP 500 on the normal
# /v1/chat/completions path). Reverts both on exit.
#
# Both providers in the broken spec are configured identically apart from the
# host, so the primary fails because that PROVIDER is unhealthy rather than
# because it was aimed at a special error path. The client URL never changes:
# every request goes to /chat/v1/chat/completions and the pool is tried in
# priority order.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

POLICY_JWT="${MANIFESTS_DIR}/policy-jwt.yaml"
POLICY_HEALTH="${MANIFESTS_DIR}/policy-health-retry.yaml"
BACKEND_NORMAL="${MANIFESTS_DIR}/agentgatewaybackend-multi.yaml"
BACKEND_BROKEN="${MANIFESTS_DIR}/agentgatewaybackend-multi-broken.yaml"

cleanup() {
  # Re-apply the normal multi-provider spec before deleting the policies.
  kubectl --context "${CLUSTER_CONTEXT}" apply -f "${BACKEND_NORMAL}" >/dev/null 2>&1 || true
  delete_and_wait "${POLICY_HEALTH}"
  delete_and_wait "${POLICY_JWT}"
  # Older revisions of policy-health-retry.yaml also shipped a `failover-retry`
  # policy, which masks req 1's 500 and makes this demo look broken. It is no
  # longer in the manifest, so delete_and_wait above won't remove a copy left
  # behind by a previous run.
  kubectl --context "${CLUSTER_CONTEXT}" delete enterpriseagentgatewaypolicy failover-retry \
    -n "${AGENTGATEWAY_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
}
trap 'cleanup; _cleanup_portforwards' EXIT

print_failover_overview() {
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  How priority-group failover works${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo "  Multiple providers ranked into priority groups (0 = primary,"
  echo "  1 = fallback). A health policy watches responses for 5xx/429/401."
  echo "  When it sees a failure, it EVICTS the offending provider for a"
  echo "  cooldown window. Next request routes to the next group silently."
  echo ""
  echo -e "  ${YELLOW}Important:${NC} the request that TRIPS the eviction still gets the"
  echo "  bad response. Eviction is the policy's reaction AFTER the failure"
  echo "  — req 1 will see 500. Reqs 2+ will see fallback's 200."
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  Flow${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  cat <<'EOF'

  ┌────────┐  POST /chat ┌────────────────────────────────────┐
  │ Client │ ──────────▶ │ Gateway (multi-provider backend)   │
  └────────┘             │   group 0  primary (broken in demo)│
                         │   group 1  mock-llm fallback       │
                         └────────────────────────────────────┘

  req 1:  group 0 → primary returns HTTP 500
                  ↓
          policy-health-retry  ▶  EVICT group 0 (cooldown)
                  ↓
          Client sees: HTTP 500   ← the bad response is unavoidable

  req 2:  group 0 evicted → group 1 (mock-llm)
          Client sees: HTTP 200 from mock-llm-1

  req 3:  group 0 still evicted → group 1
          Client sees: HTTP 200 from mock-llm-1

  (after cooldown: group 0 retested; if healthy, traffic returns)

EOF
}

demo_header "Pillar 2 · LLM Routing — Failover"

print_failover_overview
prompt_continue "Press Enter to start."

demo_step "1. Show the health (eviction) policy"
show_file "${POLICY_HEALTH}"
prompt_continue

demo_step "2. Apply JWT + health (eviction) policies"
apply_and_wait "${POLICY_JWT}"
apply_and_wait "${POLICY_HEALTH}"

demo_step "3. Swap the multi-provider backend to the broken spec (primary → unhealthy provider)"
apply_and_wait "${BACKEND_BROKEN}"

demo_step "4. Fire 3 requests — #1 primes eviction, #2+ fail over"
ensure_gateway_portforward
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")
USER_PROMPT="who is serving this response?"
say_prompt "${USER_PROMPT}"
OUT=$(mktemp)
for i in 1 2 3; do
  code=$(curl -sS -o "${OUT}" -w "%{http_code}" -X POST \
    "${GATEWAY_URL}/chat/v1/chat/completions" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "x-user-id: ${DEMO_USER_BOB}" \
    -H "Content-Type: application/json" \
    --data "$(jq -n --arg p "${USER_PROMPT}" \
      '{model:"gpt-4o",messages:[{role:"user",content:$p}]}')" \
    || echo "000")
  model=$(jq -r '.model // .error.type // "—"' "${OUT}" 2>/dev/null || echo "—")
  msg=$(jq -r '.choices[0].message.content // .error.message // "—"' "${OUT}" 2>/dev/null || echo "—")
  printf "  req %d: HTTP %s  model=%s  %s\n" "$i" "$code" "$model" "$msg"
  sleep 1
done
rm -f "${OUT}"

echo ""
echo -e "${GREEN}Expected: req 1 = 500 (primary), req 2+ = 200 from mock-llm-1.${NC}"
echo -e "${YELLOW}Broken backend + policies APPLIED. Inspect, then press Enter to revert.${NC}"
prompt_continue "Press Enter to restore and exit"
