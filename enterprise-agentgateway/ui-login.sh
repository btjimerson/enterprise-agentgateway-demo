#!/bin/bash

# Open the Solo Enterprise UI over a localhost port-forward.
#
# Keycloak is an EXTERNAL server (HTTPS), so its login cookies are
# already fine. The UI itself runs in-cluster and sets its own
# Secure;SameSite=None session cookie, which a browser only stores in a secure
# context — so we reach the UI via http://localhost (a secure context) rather
# than its plain-HTTP LB. The UI's OIDC issuer was pointed at the external
# Keycloak by 02-install-ui.sh; nothing to reconfigure here.
#
# Usage: ui-login.sh        (Ctrl-C to stop the port-forward)
#
# Author: Brian Jimerson

set -eu
set -o pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/kube-context.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/kube-context.sh"

UI_PORT=4000
UI_SVC=solo-enterprise-ui

require_env() {
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then
      echo -e "${RED}ERROR: $v is not set. Source your .envrc first.${NC}" >&2; exit 1
    fi
  done
}

solo_kube_init
require_env CLUSTER_CONTEXT AGENTGATEWAY_NAMESPACE

kc() { command kubectl --context "${CLUSTER_CONTEXT}" "$@"; }

UI_NS="${AGENTGATEWAY_NAMESPACE}"

# Another process (a Docker container, say) can sit next to this port-forward
# without an error and take some of the browser's connections.
# shellcheck source=../common/port-check.sh
source "$(cd "${SCRIPT_DIR}/../common" && pwd)/port-check.sh"
port_forward_conflict "${UI_PORT}" || exit 1

echo -e "${BLUE}Port-forwarding ${UI_NS}/${UI_SVC} to localhost:${UI_PORT}...${NC}"
kc -n "${UI_NS}" port-forward "svc/${UI_SVC}" "${UI_PORT}:80" >/tmp/agw-ui-pf.log 2>&1 &
UI_PF=$!
trap 'kill "${UI_PF}" 2>/dev/null || true' EXIT
sleep 4

# Fail loudly if the port-forward died instead of silently dropping to `wait`.
if ! kill -0 "${UI_PF}" 2>/dev/null; then
  echo -e "${RED}ERROR: the port-forward exited immediately. Last lines of /tmp/agw-ui-pf.log:${NC}" >&2
  tail -5 /tmp/agw-ui-pf.log >&2 2>/dev/null || true
  exit 1
fi

echo ""
echo -e "${GREEN}Open:${NC} http://localhost:${UI_PORT}/age/   (log in as bob (password: see DEMO_USER_BOB_PASSWORD in .envrc) via ${KEYCLOAK_EXTERNAL_URL:-your Keycloak})"
echo -e "${BLUE}Port-forward running. Press Ctrl-C to stop.${NC}"
wait
