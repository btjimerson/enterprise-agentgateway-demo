#!/bin/bash
# Pillar 5 · Observability — Case 1: ClickHouse-backed audit + usage insights.
#
# What it shows
#   The agentregistry chart bundles its OWN ClickHouse
#   (Service `agentregistry-clickhouse` in AGENTREGISTRY_NAMESPACE) fed by
#   the registry's OTel telemetry collector. Agent invocations + registry
#   telemetry land here. This case connects to it, discovers the schema,
#   and shows table row counts — the queryable observability backend.
#
# Steps
#   1. Port-forward ClickHouse HTTP (8123) and confirm /ping.
#   2. SHOW DATABASES / SHOW TABLES — discover what the collector populates.
#   3. Row counts per table — non-zero once agents run (p03-deploy-01 onward).
#
# Gotcha
#   ClickHouse's HTTP API takes SQL as a `?query=` URL param OR the POST
#   body. `-G` folds --data-urlencode into the URL so it parses correctly;
#   mixing them ships the literal `query=...` as the body and errors.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

require_cmds curl jq kubectl

trap '_cleanup_portforwards' EXIT

CH_SVC="agentregistry-clickhouse"
CH_AUTH_SECRET="agentregistry-clickhouse-auth"

demo_header "Pillar 5 · Observability — ClickHouse-backed insights"

_kill_stale_pf_on_port 8123
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
  port-forward "svc/${CH_SVC}" 8123:8123 \
  >/tmp/enterprise-ar-ch-http-pf.log 2>&1 &
pid=$!
_PF_PIDS+=("${pid}")
disown "${pid}" 2>/dev/null || true
for _ in $(seq 1 20); do
  curl -sS --max-time 1 http://localhost:8123/ping 2>/dev/null | grep -q Ok && break
  sleep 0.5
done

# Credentials: prefer the chart's auth Secret, fall back to defaults.
CH_USER="${CLICKHOUSE_USER:-$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
  get secret "${CH_AUTH_SECRET}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null)}"
CH_PASS="${CLICKHOUSE_PASSWORD:-$(kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
  get secret "${CH_AUTH_SECRET}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)}"
CH_USER="${CH_USER:-default}"
CH_PASS="${CH_PASS:-password}"

ch_query() {
  local sql="$1"
  curl -sS -u "${CH_USER}:${CH_PASS}" --max-time 8 \
    -G --data-urlencode "query=${sql} FORMAT JSON" \
    http://localhost:8123/ 2>&1 \
    | jq -r '
        if type == "object" and has("data") then
          (.data | (.[0] // {}) | keys_unsorted) as $cols
          | ($cols | @tsv), (.data[] | [.[ $cols[] ]] | @tsv)
        else . end' 2>/dev/null \
    | column -t -s $'\t' 2>/dev/null \
    || echo "  (query failed or returned non-tabular output)"
}

demo_step "1. ClickHouse is up — list databases"
echo "  SHOW DATABASES"
ch_query "SHOW DATABASES"

# Pick the telemetry database (the non-system one the collector created).
CH_DB="${CLICKHOUSE_DB:-$(curl -sS -u "${CH_USER}:${CH_PASS}" --max-time 8 \
  -G --data-urlencode "query=SELECT name FROM system.databases WHERE name NOT IN ('system','INFORMATION_SCHEMA','information_schema','default') LIMIT 1 FORMAT TabSeparated" \
  http://localhost:8123/ 2>/dev/null | head -1)}"
CH_DB="${CH_DB:-otel}"
echo -e "${CYAN}  Using telemetry database: ${CH_DB}${NC}"

demo_step "2. Tables the collector populates"
echo "  SHOW TABLES FROM ${CH_DB}"
ch_query "SHOW TABLES FROM ${CH_DB}"

demo_step "3. Row counts per table (non-zero once agents run — see p03-deploy-01)"
TABLES=$(curl -sS -u "${CH_USER}:${CH_PASS}" --max-time 8 \
  -G --data-urlencode "query=SHOW TABLES FROM ${CH_DB} FORMAT TabSeparated" \
  http://localhost:8123/ 2>/dev/null)
if [ -z "${TABLES}" ]; then
  echo -e "${YELLOW}  (no tables yet — the collector creates them on first telemetry)${NC}"
else
  for t in ${TABLES}; do
    CNT=$(curl -sS -u "${CH_USER}:${CH_PASS}" --max-time 8 \
      -G --data-urlencode "query=SELECT count() FROM ${CH_DB}.${t} FORMAT TabSeparated" \
      http://localhost:8123/ 2>/dev/null | head -1)
    printf "  %-40s %s rows\n" "${t}" "${CNT:-?}"
  done
fi

echo ""
echo -e "${CYAN}Run p03-deploy-01 + chat with the agent, then re-run this to watch the${NC}"
echo -e "${CYAN}trace/log tables fill with agent-invocation telemetry.${NC}"

prompt_continue "Demo complete — press Enter to clean up"
