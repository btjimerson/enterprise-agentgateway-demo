#!/bin/bash
# Pillar 9 · Case 2: guardrails in front of self-hosted models.
#
# Inspecting prompts before they reach a model, and completions before they reach
# the caller. Two directions with two different actions, which is the distinction
# worth drawing:
#
#   request  -> Reject : the prompt never reaches the model. For content that
#                        must not exist in the inference path at all — a live
#                        credential, an SSN, a classification marking.
#   response -> Mask   : the completion is rewritten before the caller sees it.
#                        For content the model may process but that must not
#                        leave the boundary.
#
# Both are authored declaratively, which is the other half of the point: the
# reviewer reads the policy, not application code.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

GUARDRAILS="${MANIFESTS_DIR}/policy-vllm-guardrails.yaml"

cleanup() { delete_and_wait "${GUARDRAILS}"; }
trap 'cleanup; _cleanup_portforwards' EXIT

# See the note in p09-selfhosted-01: jwt-auth is normally absent, but a leftover
# from an interrupted p05 run would make every request here need a token.
# AUTH_ARGS is seeded with a harmless marker header so it is NEVER empty. Two
# reasons, both of which bit this script: under `set -u`, bash 3.2 (what macOS
# ships) treats "${arr[@]}" on an empty array as an unbound variable and aborts;
# and the +-guarded workaround, ${arr[@]+"${arr[@]}"}, needs an unquoted outer
# expansion that shellcheck flags as SC2068. A non-empty array sidesteps both.
AUTH_ARGS=(-H "x-demo-pillar: p09")
if kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
     get enterpriseagentgatewaypolicy jwt-auth >/dev/null 2>&1; then
  TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}")
  AUTH_ARGS+=(-H "Authorization: Bearer ${TOKEN}")
fi

# probe <label> <prompt> — fire one prompt, print status and the meaningful part
# of the body. The +-guarded array expansion is required under `set -u` on bash
# 3.2 (macOS); see the note in p09-selfhosted-01.
probe() {
  local label="$1" prompt="$2"
  echo ""
  echo -e "${CYAN}${label}${NC}"
  say_prompt "${prompt}"
  local out status
  out=$(mktemp)
  status=$(curl -sS -o "${out}" -w '%{http_code}' -X POST \
    "${GATEWAY_URL}/vllm/v1/chat/completions" \
    -H 'content-type: application/json' "${AUTH_ARGS[@]}" \
    -d "{\"model\":\"gemma-4\",\"messages\":[{\"role\":\"user\",\"content\":\"${prompt}\"}]}" \
    2>/dev/null || echo 000)
  if [ "${status}" = "200" ]; then
    echo -e "  ${GREEN}HTTP ${status}${NC} — reached the model"
    python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print("  model says:", ((d.get("choices") or [{}])[0].get("message") or {}).get("content","")[:200])
except Exception:
    print("  (unparseable body)")
' "${out}"
  else
    echo -e "  ${RED}HTTP ${status}${NC} — blocked at the gateway"
    echo "  $(head -c 220 "${out}")"
  fi
  rm -f "${out}"
}

demo_header "Pillar 9 · Self-Hosted Models — Guardrails on LLM traffic"

ensure_gateway_portforward

demo_step "1. Baseline — no guardrail policy applied yet"
probe "→ a prompt containing an SSN, with NO guardrail in place" \
  "please review employee record, SSN 223-25-2789"
echo ""
echo -e "${YELLOW}That PII reached the model. Nothing stopped it.${NC}"
prompt_continue

demo_step "2. The guardrail policy"
echo "builtins are maintained detectors, so common PII does not rely on"
echo "hand-written regex. matches adds deployment-specific patterns."
show_file "${GUARDRAILS}"
prompt_continue

demo_step "3. Apply it"
apply_and_wait "${GUARDRAILS}"

demo_step "4. Request-side Reject — the prompt never reaches the model"
probe "→ SSN (builtin detector)"          "please review employee record, SSN 223-25-2789"
probe "→ live AWS key (custom pattern)"   "here is my key AKIAIOSFODNN7EXAMPLE please debug"
probe "→ classification marking"          "summarize this SECRET//NOFORN cable"
probe "→ credential in key=value form"    "the api_key = supersecrettoken123456 is failing"
prompt_continue

demo_step "5. A benign prompt still passes — guardrails are not a blanket block"
probe "→ benign" "what is the capital of France"
prompt_continue

demo_step "6. Response-side Mask — allowed through, rewritten on the way out"
echo "Email is NOT in the reject list, so this prompt reaches the model. The"
echo "response guard redacts it before the caller sees it."
probe "→ email address in the prompt" \
  "repeat this back to me: contact alice@example.com for access"
echo ""
echo -e "${GREEN}Reject protects the model. Mask protects the caller.${NC}"
echo -e "${GREEN}Both are policy, reviewable without reading application code.${NC}"

prompt_continue "Press Enter to remove the guardrail policy and finish"
