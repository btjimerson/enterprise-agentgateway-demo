#!/bin/bash
# Pillar 2 · Case 10: LLM spend budgets (EnterpriseAgentgatewayBudget, 2026.6.3).
#
# ─────────────────────────────────────────────────────────────────────
# WHY THIS PATTERN
# ─────────────────────────────────────────────────────────────────────
# p02-routing-08 caps TOKENS/min via a raw RateLimitConfig — short-window
# burst control. This is the long-window counterpart. The
# EnterpriseAgentgatewayBudget CRD is a higher-level, declarative spend
# limit: budgets measured in USD or Tokens, over Day/Week/Month/Year
# windows, with Audit (log overage, allow) or Block (HTTP 429) enforcement.
#
# Two resources, cleanly separated so platform teams own budgets and app
# teams own routes:
#   1. EnterpriseAgentgatewayBudget   — DEFINES the limits (does nothing alone).
#   2. EnterpriseAgentgatewayPolicy    — entBudgetEnforcement turns a budget ON
#      for the route it targets. Only the targeted route is affected.
#
# This demo declares a 500-token/week Audit entry + a 2000-token/day Block entry,
# enforces both on /budget-demo, burns them live (200s → 429), shows the Audit
# overage in the proxy log, and proves the un-targeted /budget-control route is
# untouched.
#
# ─────────────────────────────────────────────────────────────────────
# THREE GOTCHAS (all hit while building this)
# ─────────────────────────────────────────────────────────────────────
#  * The controller only watches the budgets CRD if it started AFTER the CRD
#    was installed. On a cluster upgraded into 2026.6.3, restart it once:
#      kubectl -n agentgateway-system rollout restart deploy/enterprise-agentgateway
#    (Symptom: budgets get no .status and never enforce.)
#  * Both entries are Tokens but use DIFFERENT windows on purpose. The CRD
#    rejects duplicate (subject, unit, window) combinations, so two no-subject
#    Tokens entries cannot both be Day. See budget-crd.yaml.
#  * USD budgets are NOT demonstrable here, which is why neither entry uses them:
#    they need a model cost catalog (EnterpriseAgentgatewayParameters.spec.modelCatalog,
#    installed from manifests/model-costs.yaml; models it does not price contribute
#    nothing to USD spend), AND USD amounts are whole dollars with a minimum of 1, while these requests
#    cost a fraction of a cent each. USD amounts are illustrative, not demonstrable live.
#
# Docs: https://docs.solo.io/agentgateway/latest/llm/cost-controls/budget-limits/

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

ROUTES="${MANIFESTS_DIR}/httproute-budget-demo.yaml"
BUDGET="${MANIFESTS_DIR}/budget-crd.yaml"
POLICY="${MANIFESTS_DIR}/policy-budget-enforcement.yaml"
PROMPT='{"model":"gpt-4o","messages":[{"role":"user","content":"Explain Kubernetes in detail, about 400 words."}]}'

cleanup() {
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" delete -f "${POLICY}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" delete -f "${BUDGET}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" delete -f "${ROUTES}" --ignore-not-found >/dev/null 2>&1 || true
}
trap 'cleanup; _cleanup_portforwards' EXIT

print_overview() {
  echo ""
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  Budgets, not rate limits${NC}"
  echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
  echo "  An EnterpriseAgentgatewayBudget holds budget entries, each with a"
  echo -e "  ${YELLOW}limit${NC} (USD or Tokens), a ${YELLOW}window${NC} (Day/Week/Month/Year), and"
  echo -e "  ${YELLOW}onBudgetExceeded${NC} = Audit (log, allow) or Block (HTTP 429)."
  echo ""
  echo "  Safe rollout: Audit first (meter real spend, block nothing) →"
  echo "  Block later (once you trust the numbers). A budget does NOTHING"
  echo -e "  until an ${YELLOW}entBudgetEnforcement${NC} policy turns it on for a route."
  echo ""
  cat <<'EOF'
   EnterpriseAgentgatewayBudget           EnterpriseAgentgatewayPolicy
     demo-token-audit (500/week,  Audit)    entBudgetEnforcement ─▶ HTTPRoute /budget-demo
     demo-token-block (2000/day,  Block)    (NOT targeting /budget-control)
EOF
  echo ""
  echo "  Both entries are debited by every request, and the audit limit is the"
  echo "  lower one — so the same traffic crosses Audit first (allowed, logged)"
  echo "  and Block later (429). That's the rollout story in one run."
  echo ""
  echo -e "${CYAN}  Steps: ${YELLOW}①${NC} show resources, ${YELLOW}②${NC} apply, ${YELLOW}③${NC} burn the token budget${NC}"
  echo -e "${CYAN}  (200s → 429), ${YELLOW}④${NC} show the Audit overage in the proxy log,${NC}"
  echo -e "${CYAN}  ${YELLOW}⑤${NC} prove /budget-control is untouched.${NC}"
  echo ""
}

demo_header "Pillar 2 · LLM Routing — Spend Budgets (EnterpriseAgentgatewayBudget)"
print_overview
prompt_continue "Press Enter to start."

demo_step "① Show the budget, the enforcement policy, and the routes"
show_file "${BUDGET}"
show_file "${POLICY}"
show_file "${ROUTES}"
prompt_continue

demo_step "② Apply routes + budget + enforcement policy on cluster1"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" apply -f "${ROUTES}"
# The token counter is keyed by budget-entry name and persists for the whole
# Day window (deleting the budget does NOT reset it). So each run gets fresh
# entry names — otherwise a re-run within the same day starts already-exhausted
# (immediate 429 with no 200s). The budget RESOURCE name stays budget-demo, so
# cleanup by file still matches.
SUFFIX="$(date +%H%M%S)"
BUDGET_RENDERED="$(mktemp)"
sed "s/demo-token-audit/demo-token-audit-${SUFFIX}/; s/demo-token-block/demo-token-block-${SUFFIX}/" \
  "${BUDGET}" > "${BUDGET_RENDERED}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" apply -f "${BUDGET_RENDERED}"
rm -f "${BUDGET_RENDERED}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" apply -f "${POLICY}"
echo "  waiting for the route to be Accepted + config to propagate..."
for _ in $(seq 1 20); do
  acc=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" get httproute budget-demo \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
  [ "${acc}" = "True" ] && break; sleep 1
done
sleep 8   # let the enforcement filter land on the proxy

ensure_gateway_portforward

demo_step "③ Burn the 2000-token/day budget — each ~550-token request counts; expect 200s then 429"
OUT=$(mktemp); ok=0; blocked=0
for i in $(seq 1 8); do
  code=$(curl -sS -o "${OUT}" -w '%{http_code}' --max-time 60 -X POST "${GATEWAY_URL}/budget-demo" \
    -H "Content-Type: application/json" -d "${PROMPT}")
  toks=$(jq -r '.usage.total_tokens // "-"' "${OUT}" 2>/dev/null)
  case "${code}" in
    200) ok=$((ok+1));      echo -e "  request ${i} → ${GREEN}HTTP 200${NC} (tokens: ${toks})" ;;
    429) blocked=$((blocked+1)); echo -e "  request ${i} → ${YELLOW}HTTP 429 — budget exceeded${NC}"; break ;;
    *)   echo -e "  request ${i} → ${RED}HTTP ${code}${NC} $(head -c 100 "${OUT}")" ;;
  esac
done
rm -f "${OUT}"
echo ""
if [ "${blocked}" -ge 1 ]; then
  echo -e "${GREEN}✓ Budget enforced: ${ok} requests passed, then 429 once the 2000-token/day cap was hit.${NC}"
else
  echo -e "${RED}✗ No 429 after ${ok} requests. If budgets never enforce here, the controller${NC}"
  echo -e "${RED}  likely predates the budgets CRD — restart it (see header) and re-run.${NC}"
fi

demo_step "④ The Audit entry: over its limit, logged, but NOT blocked"
echo "  demo-token-audit is 500 tokens/week — the run above blew past it long"
echo "  before the 2000/day Block entry tripped. Audit never rejects, so those"
echo -e "  requests returned ${GREEN}200${NC}; the evidence is in the proxy log:"
echo ""
# Scope the grep to THIS run's entry name. Entry names carry a per-run ${SUFFIX},
# so matching on it prevents a previous run's audit lines (which --since alone
# will happily pick up) from being reported as this run's success.
AUDIT_LOG=$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  logs deploy/agentgateway-proxy --since=10m 2>/dev/null \
  | grep 'over_limit_audit' | grep "demo-token-audit-${SUFFIX}" | tail -3)
if [ -n "${AUDIT_LOG}" ]; then
  echo "${AUDIT_LOG}" | sed 's/^/    /'
  echo ""
  echo -e "  ${GREEN}✓ Audit overage logged (outcome=\"over_limit_audit\") while the request passed.${NC}"
  echo -e "  ${CYAN}This is the safe-rollout pattern: run Audit in production to see what a${NC}"
  echo -e "  ${CYAN}limit WOULD block, then flip the entry to Block once you trust it.${NC}"
else
  echo -e "  ${YELLOW}No over_limit_audit lines found in the last 5m.${NC}"
  echo -e "  ${YELLOW}Check the proxy log level, or that the audit entry's limit is below${NC}"
  echo -e "  ${YELLOW}the tokens spent above:${NC}"
  echo -e "    kubectl -n ${AGENTGATEWAY_NAMESPACE} logs deploy/agentgateway-proxy | grep budget"
fi
prompt_continue

demo_step "⑤ Blast radius: /budget-control has no enforcement policy — still 200"
ctl=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST "${GATEWAY_URL}/budget-control" \
  -H "Content-Type: application/json" -d '{"model":"gpt-4o","messages":[{"role":"user","content":"ping"}]}')
echo -e "  /budget-demo  → ${YELLOW}429${NC} (locked until the window resets)"
echo -e "  /budget-control → $( [ "${ctl}" = "200" ] && echo -e "${GREEN}HTTP 200${NC} — untouched" || echo -e "${RED}HTTP ${ctl}${NC}")"

echo ""
echo -e "${GREEN}Enforcement is scoped to the route the policy targets. Budgets meter/limit${NC}"
echo -e "${GREEN}real LLM spend. Tokens work out of the box; USD is priced from the model${NC}"
echo -e "${GREEN}cost catalog, but its \$1 minimum puts it out of reach of a live run.${NC}"
echo -e "${YELLOW}Self-contained — exiting removes the routes, budget and policy.${NC}"
prompt_continue "Press Enter to tear down and exit"
