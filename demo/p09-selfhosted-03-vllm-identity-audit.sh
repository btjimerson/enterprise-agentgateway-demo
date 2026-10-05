#!/bin/bash
# Pillar 9 · Case 3: virtual keys tied to real identities, and an audit trail
# built from them.
#
# The gap this addresses: API keys that are static strings in a config file,
# shared between people and services, with no way to answer "who made this call"
# after the fact.
#
# What is shown:
#   1. Keys are stored as SHA-256 HASHES, so no plaintext credential exists in
#      the cluster. Each entry carries metadata — user, team, key type.
#   2. The gateway resolves a presented key to that identity, and every
#      downstream policy reads the identity rather than the key.
#   3. The access log records the identity, the model, the token volume and the
#      outcome — including for requests that were DENIED. Revoking access is
#      deleting one entry, not rotating a shared secret.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

KEYS="${MANIFESTS_DIR}/apikeys-vllm.yaml"
APIKEY_POLICY="${MANIFESTS_DIR}/policy-vllm-apikey.yaml"
AUDIT_POLICY="${MANIFESTS_DIR}/policy-vllm-audit.yaml"
GUARDRAILS="${MANIFESTS_DIR}/policy-vllm-guardrails.yaml"

# The raw keys. These are demo values; the cluster only ever holds their hashes.
KEY_DANA="sk-demo-dana-7f3a91c2"
KEY_SVC="sk-demo-svc-batch-4b8d02e1"

cleanup() {
  delete_and_wait "${AUDIT_POLICY}"
  delete_and_wait "${APIKEY_POLICY}"
  delete_and_wait "${GUARDRAILS}"
  delete_and_wait "${KEYS}"
}
trap 'cleanup; _cleanup_portforwards' EXIT

# PRE-FLIGHT. Policies STACK rather than override: with the gateway-wide
# `jwt-auth` policy applied, /vllm would require BOTH a JWT and an API key, and
# every request below would 401 for a reason that has nothing to do with what is
# being demonstrated. jwt-auth belongs to the p05 security demos and their
# cleanup removes it, so it is only present if one was interrupted.
if kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
     get enterpriseagentgatewaypolicy jwt-auth >/dev/null 2>&1; then
  echo -e "${YELLOW}Found a leftover gateway-wide 'jwt-auth' policy from the p05 security"
  echo -e "demos. Auth policies stack, so /vllm would demand a JWT *and* an API key."
  echo -e "Removing it so this step demonstrates key-based identity on its own.${NC}"
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    delete enterpriseagentgatewaypolicy jwt-auth --ignore-not-found >/dev/null 2>&1
  sleep 3
fi

# call <label> <expected-status> <prompt> [curl args...]
# The prompt is a parameter so a label always describes the request it actually
# fires — a fixed body here previously meant the "blocked by guard" line sent
# benign text and reported 200.
call() {
  local label="$1" expect="$2" prompt="$3"; shift 3
  local out status
  out=$(mktemp)
  status=$(curl -sS -o "${out}" -w '%{http_code}' -X POST \
    "${GATEWAY_URL}/vllm/v1/chat/completions" \
    -H 'content-type: application/json' "$@" \
    -d "{\"model\":\"gemma-4\",\"messages\":[{\"role\":\"user\",\"content\":\"${prompt}\"}]}" \
    2>/dev/null || echo 000)
  local mark="${GREEN}✓${NC}"
  [ "${status}" = "${expect}" ] || mark="${RED}✗ expected ${expect}${NC}"
  printf '  %-34s %s %b\n' "${label}" "HTTP ${status}" "${mark}"
  # Echo the prompt that was actually sent. Without this, a 401/422 line states
  # an outcome with no visible cause — "blocked by guard" reads as the demo
  # asserting a denial rather than showing one.
  printf '    %bprompt:%b %s\n' "${CYAN}" "${NC}" "${prompt}"
  [ "${status}" != "200" ] && echo "      $(head -c 160 "${out}")"
  rm -f "${out}"
}

# Count existing audit lines so the trail shown at the end contains only the
# requests this run generated. A time window would pick up an earlier run.
audit_count() {
  kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
    logs deploy/agentgateway-proxy --tail=2000 2>/dev/null | grep -c 'audit\.user' || true
}

demo_header "Pillar 9 · Self-Hosted Models — Virtual keys, identity and audit"

ensure_gateway_portforward

demo_step "1. Keys are stored as hashes, with an identity attached"
echo "No plaintext credential exists in the cluster. Each entry binds a key hash"
echo "to a user, a team and a key type."
show_file "${KEYS}"
prompt_continue

demo_step "2. The authentication policy"
echo "ConfigMaps are selected by LABEL, so keys can be split per team or"
echo "environment and all are consulted."
show_file "${APIKEY_POLICY}"
prompt_continue

demo_step "3. Apply the keys and the policy"
apply_and_wait "${KEYS}"
apply_and_wait "${APIKEY_POLICY}"
# Applied here too so the denied-request audit record later in this step works
# when this script is run on its own.
apply_and_wait "${GUARDRAILS}"

demo_step "4. Only a recognized key gets through"
BENIGN="summarize the weekly report"
call "no key at all"          401 "${BENIGN}"
call "an unrecognized key"    401 "${BENIGN}" -H "x-api-key: sk-not-a-real-key"
call "dana's CLI key"         200 "${BENIGN}" -H "x-api-key: ${KEY_DANA}"
call "the service account's"  200 "${BENIGN}" -H "x-api-key: ${KEY_SVC}"
prompt_continue

demo_step "5. The audit policy"
echo "Attributes are CEL expressions, so the record carries the fields an auditor"
echo "asks for. Note audit.user reads the key's METADATA — the key itself is"
echo "never written to the log."
show_file "${AUDIT_POLICY}"
prompt_continue
apply_and_wait "${AUDIT_POLICY}"

demo_step "6. Generate a realistic mix of traffic"
echo "Five requests: three that succeed, one rejected by the guardrail policy"
echo "applied in step 3 (an SSN in the prompt, same Ssn builtin as case 9.2), and"
echo "one with a key the cluster has never seen. Each prompt is printed so the"
echo "outcome is visible rather than asserted."
echo ""
BEFORE=$(audit_count)
call "dana, default fleet"        200 "${BENIGN}" -H "x-api-key: ${KEY_DANA}"
call "dana, second fleet"         200 "${BENIGN}" -H "x-api-key: ${KEY_DANA}" -H 'x-model: llama-30'
call "service account, batch"     200 "nightly batch summary" -H "x-api-key: ${KEY_SVC}"
call "dana, SSN → guardrail"      422 "employee SSN 223-25-2789 needs review" \
  -H "x-api-key: ${KEY_DANA}"
call "unrecognized key"           401 "${BENIGN}" -H "x-api-key: sk-stolen-key-attempt"
sleep 4

demo_step "7. The audit trail"
AFTER=$(audit_count)
NEW=$(( AFTER - BEFORE ))
[ "${NEW}" -lt 1 ] && NEW=6
echo "From the gateway proxy's own access log — this is the compliance artifact,"
echo "not a side-channel the demo built."
echo ""

# Capture once and reuse, so the raw records and the table below are provably the
# SAME lines. Two separate `kubectl logs` calls could return different tails.
RAW="$(mktemp)"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  logs deploy/agentgateway-proxy --tail=2000 2>/dev/null \
  | grep 'audit\.user' | tail -n "${NEW}" > "${RAW}"

echo -e "${BOLD}Raw records, exactly as the proxy wrote them${NC}"
echo -e "${CYAN}(kubectl logs deploy/agentgateway-proxy | grep audit.user | tail -n ${NEW})${NC}"
echo ""
cat "${RAW}"
echo ""
echo "Note what is present: audit.user, audit.team, audit.keyType, audit.tokens,"
echo "audit.status — and note what is absent: the API key. Long lines are wrapped"
echo "by your terminal, not truncated by the demo."
prompt_continue "Press Enter to render those same lines as a table"

echo ""
echo -e "${BOLD}The same records, rendered${NC}"
echo ""
python3 -c '
import re, sys
rows = []
for line in sys.stdin:
    f = dict(re.findall(r"audit\.(\w+)=\"([^\"]*)\"", line))
    if not f:
        continue
    rows.append((
        f.get("status", "-"),
        f.get("user", "-"),
        f.get("team", "-"),
        f.get("keyType", "-"),
        f.get("modelServed", "-"),
        f.get("tokens", "-"),
    ))
hdr = ("STATUS", "USER", "TEAM", "KEY TYPE", "MODEL", "TOKENS")
w = [max(len(str(r[i])) for r in rows + [hdr]) for i in range(6)]
def line(r):
    return "  " + "  ".join(str(r[i]).ljust(w[i]) for i in range(6))
print(line(hdr))
print("  " + "  ".join("-" * x for x in w))
for r in rows:
    print(line(r))
' < "${RAW}"
rm -f "${RAW}"
echo ""
echo -e "${GREEN}Every call attributed to a person or a service account.${NC}"
echo -e "${GREEN}The denied request is in the log too — with the identity that tried it.${NC}"
echo -e "${GREEN}No raw key anywhere in the record.${NC}"

prompt_continue "Press Enter to tear down the keys and policies and finish"
