#!/bin/bash
# Pillar 5 · Case 7: Self-service virtual keys with fine-grained RBAC.
#
# The Solo UI runs with rbac.mode=fine-grained (the demo baseline). In
# that mode every signed-in user can view and manage ONLY the virtual keys whose
# `user` metadata is theirs — no policy needed — and the global.Admin role does
# NOT imply access to virtual keys. Admins get it from an explicit
# EnterpriseAgentgatewayRBACPolicy (manifests/rbac-virtual-keys-admins.yaml).
#
# This script checks the mode, shows the admin grant, seeds one key per demo user
# (alice / bob / reader-user) and then hands over to the UI: the proof is
# signing in as each user and watching Virtual Keys change. It makes no Keycloak
# calls itself.
#
#   1. Verify the management release is in fine-grained mode
#   2. Show the admin grant
#   3. Seed one key per demo user
#   4. UI: bob sees only bob-key; reader-user only reader-key; alice sees all
#   5. UI: bob creating a key for alice is denied; for bob it succeeds
#
# Usage: p05-security-07-virtual-key-rbac.sh        (DEMO_KEEP=1 skips cleanup)
#
# Gotchas:
#  * The same mode also governs budgets, budget entries and HTTPRoutes.
#  * A user whose groups map to NO role (e.g. dana, support-engineers) gets a
#    "Server Error" page on an agentgateway-only install. Use alice, bob or
#    reader-user.
#  * After a failed create the red error toast can cover the Create button; reload
#    the form before the next attempt.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(cd "${SCRIPT_DIR}/../manifests" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

KEYS_MANIFEST="${MANIFESTS_DIR}/virtual-keys-rbac-demo.yaml"
GRANT_MANIFEST="${MANIFESTS_DIR}/rbac-virtual-keys-admins.yaml"

cleanup() {
  if [ "${DEMO_KEEP:-0}" = "1" ]; then
    echo -e "${YELLOW}DEMO_KEEP=1 — leaving the demo keys in place.${NC}"
    return
  fi
  delete_and_wait "${KEYS_MANIFEST}"
}
trap 'cleanup' EXIT

demo_header "Pillar 5 · Security — self-service virtual keys (fine-grained RBAC)"

demo_step "1. The Solo UI is in fine-grained RBAC mode"
MODE=$(helm --kube-context "${CLUSTER_CONTEXT}" get values management \
  -n "${AGENTGATEWAY_NAMESPACE}" -a -o json 2>/dev/null | jq -r '.rbac.mode // "unknown"')
echo -e "${CYAN}rbac.mode =${NC} ${MODE}"
if [ "${MODE}" != "fine-grained" ]; then
  echo -e "${RED}ERROR: expected fine-grained. Re-run ./02-install-ui.sh with UI_RBAC_MODE=fine-grained.${NC}" >&2
  exit 1
fi
prompt_continue

demo_step "2. Admins need an explicit grant — global.Admin does not imply virtual keys"
show_file "${GRANT_MANIFEST}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  get enterpriseagentgatewayrbacpolicies
prompt_continue

demo_step "3. Seed one key per demo user"
apply_and_wait "${KEYS_MANIFEST}"
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTGATEWAY_NAMESPACE}" \
  get secret vk-rbac-demo -o json | jq -r '.data | to_entries[] | "\(.key)\t\(.value | @base64d | fromjson | .metadata.user)"'

echo ""
echo -e "${BOLD}Open the UI:${NC} ./ui-login.sh  →  http://localhost:4000/age/virtual-keys/"
echo -e "Use a private window per user, or end the Keycloak session between users"
echo -e "(<keycloak>/realms/solo/protocol/openid-connect/logout)."

demo_step "4. List filtering — what each user sees"
echo -e "  ${CYAN}bob${NC}          (writers)  → only bob-key"
echo -e "  ${CYAN}reader-user${NC}  (readers)  → only reader-key"
echo -e "  ${CYAN}alice${NC}        (admins)   → every key, via the admin grant"
prompt_continue

demo_step "5. Creating keys"
echo -e "  As ${CYAN}bob${NC}: Create Virtual API Key, Key Set vk-rbac-demo, User ${BOLD}bob${NC}   → succeeds"
echo -e "  As ${CYAN}bob${NC}: same, User ${BOLD}alice${NC}  → \"a matching manage grant must cover the target\""
echo -e "  As ${CYAN}alice${NC}: User ${BOLD}bob${NC}  → succeeds (admin grant)"
echo -e "The raw key is shown once, at creation. Keys the UI creates land in the Secret"
echo -e "and are removed with it when this script exits."
prompt_continue "Press Enter to clean up the demo keys"
