#!/bin/bash
# Pillar 7 · Case 1: Grafana dashboards for agentgateway.
#
# Fires continuous background load through /chat, /a2a, AND MCP (with the
# proper initialize → notifications/initialized → tools/list handshake) so
# the dashboards have live, non-decaying data. Port-forwards Grafana and
# prints the URL + credentials + which dashboards/rows to inspect.
#
# Lessons from the v1 of this script (which produced an empty dashboard):
#
#   1. The load loop fired naive `tools/list` requests against /mcp
#      without doing the initialize handshake first. The proxy rejected
#      them with HTTP 422 ("session header is required"), and the proxy's
#      `agentgateway_mcp_requests_total` counter only ticks on requests
#      that pass into a session, so the MCP row stayed empty.
#   2. The load ran for 30s, then the user clicked around for minutes.
#      The dashboards use `rate(metric[5m])`, which decays to 0 once the
#      load stops. Result: empty graphs by the time the user looked.
#   3. Default Grafana time range (Last 6h / 24h) makes a 30s burst a
#      single-pixel spike. We tell the user upfront to set "Last 5m" +
#      auto-refresh 5s so the live load is visible.
#
# This version solves all three by keeping a background load_loop alive
# until the user dismisses the script, with proper MCP sessions, mixed
# traffic shape (chat + a2a + mcp), and an upfront UX hint.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

: "${OBSERVABILITY_NAMESPACE:=monitoring}"
: "${DEMO_USER_BOB:=bob}"
: "${DEMO_USER_BOB_PASSWORD:?set DEMO_USER_BOB_PASSWORD in .envrc (see .envrc.sample)}"

LOAD_PID=""
load_cleanup() {
  [ -n "${LOAD_PID:-}" ] && kill "${LOAD_PID}" 2>/dev/null || true
  pkill -P $$ -f load_loop 2>/dev/null || true
}
trap 'load_cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 7 · Observability — Grafana"

demo_step "1. Verify Grafana + Prometheus are running"
kubectl --context "${CLUSTER_CONTEXT}" -n "${OBSERVABILITY_NAMESPACE}" get pods 2>&1 \
  | grep -E "NAME|grafana|prometheus" | head -10

demo_step "2. Start continuous load (chat + a2a + mcp) in the background"
ensure_gateway_portforward
TOKEN=$(get_jwt "${DEMO_USER_BOB}" "${DEMO_USER_BOB_PASSWORD}" 2>/dev/null || true)
if [ -z "${TOKEN:-}" ]; then
  echo -e "${RED}ERROR: could not mint a JWT for ${DEMO_USER_BOB}.${NC}" >&2
  exit 1
fi

# load_loop: fires /chat, /a2a, and proper-MCP traffic in a loop.
# Running this as a background subshell lets the script proceed to
# port-forward Grafana while load is sustained. The trap kills it on
# exit. JWT is captured by closure; if it expires (Keycloak access
# token TTL ≈ 5min), the demo is intended to wrap up anyway.
load_loop() {
  local accept="application/json, text/event-stream"
  # MCP needs a session — do the handshake once, then reuse.
  local mcp_h mcp_b session
  mcp_h=$(mktemp); mcp_b=$(mktemp)
  curl -sS -D "${mcp_h}" -o "${mcp_b}" -X POST "${GATEWAY_URL}/mcp" \
    -H "Authorization: Bearer ${TOKEN}" -H "Accept: ${accept}" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{
          "protocolVersion":"2024-11-05","capabilities":{},
          "clientInfo":{"name":"obs-load","version":"1.0"}}}' 2>/dev/null
  session=$(awk -v IGNORECASE=1 -F': ' \
    'tolower($1)=="mcp-session-id" {gsub(/\r/,"",$2); print $2; exit}' "${mcp_h}")
  curl -sS -o /dev/null -X POST "${GATEWAY_URL}/mcp" \
    -H "Authorization: Bearer ${TOKEN}" -H "Accept: ${accept}" \
    -H "Content-Type: application/json" -H "Mcp-Session-Id: ${session}" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' 2>/dev/null
  rm -f "${mcp_h}" "${mcp_b}"

  while :; do
    # /chat — populates Requests + LLM rows.
    curl -sS -o /dev/null --max-time 5 -X POST "${GATEWAY_URL}/chat/v1/chat/completions" \
      -H "Authorization: Bearer ${TOKEN}" -H "x-user-id: ${DEMO_USER_BOB}" \
      -H "Content-Type: application/json" \
      -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}' &
    # /a2a — populates Requests row with route=a2a label.
    curl -sS -o /dev/null --max-time 5 -X POST "${GATEWAY_URL}/a2a" \
      -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":"1","method":"tasks/send","params":{"id":"1","message":{"role":"user","parts":[{"type":"text","text":"ping"}]}}}' &
    # /mcp — populates MCP row. Must use the captured session.
    curl -sS -o /dev/null --max-time 5 -X POST "${GATEWAY_URL}/mcp" \
      -H "Authorization: Bearer ${TOKEN}" -H "Accept: ${accept}" \
      -H "Content-Type: application/json" -H "Mcp-Session-Id: ${session}" \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' &
    wait
    sleep 1
  done
}
load_loop >/dev/null 2>&1 &
LOAD_PID=$!
disown "${LOAD_PID}" 2>/dev/null || true
echo -e "  load_loop pid: ${CYAN}${LOAD_PID}${NC} (will be killed on exit)"

demo_step "3. Port-forward Grafana on localhost:3000"
_kill_stale_pf_on_port 3000
kubectl --context "${CLUSTER_CONTEXT}" -n "${OBSERVABILITY_NAMESPACE}" \
  port-forward svc/grafana 3000:80 >/tmp/agw-grafana-pf.log 2>&1 &
pid=$!
_PF_PIDS+=("${pid}")
disown "${pid}" 2>/dev/null || true
for _ in $(seq 1 40); do
  if curl -sS --max-time 1 http://localhost:3000/api/health -o /dev/null 2>/dev/null; then
    break
  fi
  sleep 0.5
done

echo ""
echo -e "${GREEN}Grafana is up; load is firing in the background.${NC}"
echo -e "  URL:        ${CYAN}http://localhost:3000${NC}"
echo -e "  User/pass:  ${CYAN}admin / admin${NC}"
echo ""
echo -e "${CYAN}# What to look at${NC}"
echo -e "  Both dashboards live in the ${YELLOW}Agentgateway${NC} folder:"
echo -e "    Dashboards → Agentgateway → ${YELLOW}Agentgateway${NC}"
echo -e "      rows: Overview · Requests · LLM · MCP"
echo -e "    Dashboards → Agentgateway → ${YELLOW}Agentgateway — Tokens, Cost, Latency${NC}"
echo ""
echo -e "${CYAN}# Important${NC}"
echo -e "  Set time range to ${YELLOW}Last 5 minutes${NC} (top right)."
echo -e "  Set refresh to ${YELLOW}5s${NC} (icon next to the range)."
echo -e "  Otherwise the live load is a thin spike inside a wide window."
echo ""

# `disown` above removes the port-forward from this shell's job table,
# which makes `wait ${pid}` return immediately — triggering the EXIT
# trap and killing the port-forward before the user sees anything.
# Block on user input instead. prompt_continue respects DEMO_AUTO=1
# for CI (skips the wait, port-forward + load are cleaned up on exit).
prompt_continue "Press Enter to stop load + port-forward and exit"
