#!/bin/bash
# Seed synthetic telemetry into ClickHouse so the agentgateway Solo UI shows
# realistic COST **and** TRACE data WITHOUT any LLM API calls or charges.
#
# It seeds at the SOURCE table the gateway itself writes to — platformdb
# .otel_traces_json — so the whole materialized-view chain cascades exactly like
# real traffic:
#
#   otel_traces_json ──agw_spans_typed_mv──▶ agw_spans_typed ──▶ cost rollups
#        │                                        (agw_cost_model_5m / _dimensions_5m)
#        │                                    └─▶ trace rollups
#        │                                        (agw_trace_model/route/tool/request_counts_5m)
#        └────────────agw_chat_spans_mv──────▶ agw_chat_spans
#
# So a single seed populates the raw Trace explorer, the Cost Management
# dashboards (per-model + per-org/team/user/virtual-key/…), and the trace
# summary rollups. Each synthetic request is a small SPAN TREE:
#   • root  (SERVER)  : the gateway request  → route / http.path / http.status
#   • llm   (CLIENT)  : the model call       → gen_ai.* + cost + custom_dimensions
#   • tool  (INTERNAL): a tool call (~1/3)    → gen_ai.tool.name
# The typed-span MV extracts flat-dotted SpanAttributes keys
# (gen_ai.request.model, gen_ai.usage.*_tokens, gen_ai.provider.name,
# agw.ai.usage.cost.total, route, http.*, gen_ai.tool.name, and
# agw.llm.custom_dimensions as a JSON array-of-pairs). It also seeds a Virtual
# API Keys Secret so that tab is populated.
#
# Idempotent: clears prior demo rows (ServiceName/service_name prefixed `demo-`)
# from the source AND every derived table first. Safe to re-run. --cleanup
# removes it.
#
# Prereqs: Solo UI installed with Cost Management enabled (02-install-ui.sh sets
# products.agentgateway.features.cost-management=true) and the ui-backend
# ClickHouse migrations applied (agw_spans_typed.CostUsd).
#
# Env: CLUSTER_CONTEXT, AGENTGATEWAY_NAMESPACE (from .envrc). Tunables:
#   NUM_REQUESTS (default 8000), LOOKBACK_DAYS (default 7).
#
# Modeled on enablement-labs local-lab 18-cost-management-demo, extended to seed
# at the trace source so both cost and trace views populate.

set -uo pipefail

: "${AGENTGATEWAY_NAMESPACE:=agentgateway-system}"
: "${NUM_REQUESTS:=8000}"
: "${LOOKBACK_DAYS:=7}"
DB=platformdb
VK_SECRET=cost-demo-virtual-keys

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'

CTX="${CLUSTER_CONTEXT:-$(kubectl config current-context 2>/dev/null)}"
NS="${AGENTGATEWAY_NAMESPACE}"
KC=(kubectl --context "${CTX}" -n "${NS}")

MODE=seed
case "${1:-}" in
  --cleanup) MODE=cleanup ;;
  -h|--help) echo "Usage: $0 [--cleanup]   (env: NUM_REQUESTS, LOOKBACK_DAYS)"; exit 0 ;;
  "") ;;
  *) echo -e "${RED}Unknown arg: $1${NC}" >&2; exit 1 ;;
esac

CH_POD="$("${KC[@]}" get pod -l app.kubernetes.io/name=clickhouse \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[ -z "${CH_POD}" ] && CH_POD="management-clickhouse-shard0-0"
if ! "${KC[@]}" get pod "${CH_POD}" >/dev/null 2>&1; then
  echo -e "${RED}ERROR: ClickHouse pod not found (${NS}/${CH_POD}). Is the Solo UI installed?${NC}" >&2
  exit 1
fi

ch() { "${KC[@]}" exec -i "${CH_POD}" -c clickhouse -- clickhouse-client -d "${DB}" --multiquery "$@"; }

# Delete demo rows from the source AND every derived table (MVs fire only on
# insert, so downstream rows must be cleared explicitly). Each DELETE runs on
# its own so one failure can't abort the rest. Demo spans carry a `demo-`
# ServiceName and a `deadbeef`-prefixed TraceId (the latter lets us clear
# agw_chat_spans, which has no service column).
DEMO_TRACE_PREFIX=deadbeef
clear_demo_rows() {
  # tables with a TraceId but no service column
  ch -q "ALTER TABLE ${DB}.agw_chat_spans DELETE WHERE TraceId LIKE '${DEMO_TRACE_PREFIX}%' SETTINGS mutations_sync = 2" >/dev/null 2>&1 || true
  # source tables (ServiceName)
  local t
  for t in otel_traces_json agw_spans_typed; do
    ch -q "ALTER TABLE ${DB}.${t} DELETE WHERE ServiceName LIKE 'demo-%' SETTINGS mutations_sync = 2" >/dev/null 2>&1 || true
  done
  # rollups (service_name)
  for t in agw_cost_model_5m agw_cost_dimensions_5m agw_trace_model_5m agw_trace_route_5m agw_trace_tool_5m agw_trace_request_counts_5m; do
    ch -q "ALTER TABLE ${DB}.${t} DELETE WHERE service_name LIKE 'demo-%' SETTINGS mutations_sync = 2" >/dev/null 2>&1 || true
  done
}

if [ "${MODE}" = "cleanup" ]; then
  echo -e "${BLUE}Removing seeded demo telemetry (demo-% rows) on ${CTX}...${NC}"
  clear_demo_rows
  "${KC[@]}" delete secret "${VK_SECRET}" --ignore-not-found >/dev/null 2>&1 || true
  echo -e "${GREEN}Cleanup complete.${NC}"
  exit 0
fi

echo -e "${BLUE}Waiting for the ClickHouse spend migration (agw_spans_typed.CostUsd)...${NC}"
migrated=0
for _ in $(seq 1 60); do
  n="$(ch -q "SELECT count() FROM system.columns WHERE database='${DB}' AND table='agw_spans_typed' AND name='CostUsd'" 2>/dev/null | tr -d '[:space:]')"
  if [ "${n}" = "1" ]; then migrated=1; break; fi
  sleep 5
done
if [ "${migrated}" != "1" ]; then
  echo -e "${RED}ERROR: agw_spans_typed.CostUsd not present — the ui-backend migrations have not completed.${NC}" >&2
  echo -e "${RED}If the controller/UI predates the 2026.6.3 upgrade, restart the UI and retry.${NC}" >&2
  exit 1
fi

echo -e "${BLUE}Clearing any previous demo rows (demo-% )...${NC}"
clear_demo_rows

echo -e "${BLUE}Seeding ${NUM_REQUESTS} synthetic request traces (root + llm + ~1/3 tool spans) across the last ${LOOKBACK_DAYS} days...${NC}"
ch >/dev/null <<SQL
INSERT INTO ${DB}.otel_traces_json
    (Timestamp, TraceId, SpanId, ParentSpanId, SpanName, SpanKind, ServiceName, ScopeName, Duration, StatusCode, SpanAttributes)
SELECT
    root_ts + toIntervalNanosecond(multiIf(role = 'root', 0, role = 'llm', 8000000, 15000000)) AS Timestamp,
    trace_id AS TraceId,
    substring(lower(hex(MD5(concat(toString(req), '-', role)))), 1, 16) AS SpanId,
    multiIf(role = 'root', '', role = 'llm', root_span, tool_span_parent) AS ParentSpanId,
    multiIf(role = 'root', concat('POST ', route), role = 'llm', concat('chat ', model), concat('execute_tool ', tool_name)) AS SpanName,
    multiIf(role = 'root', 'SPAN_KIND_SERVER', role = 'llm', 'SPAN_KIND_CLIENT', 'SPAN_KIND_INTERNAL') AS SpanKind,
    service_name AS ServiceName,
    'agentgateway' AS ScopeName,
    multiIf(role = 'root', dur_root, role = 'llm', dur_llm, dur_tool) AS Duration,
    if(role = 'root' AND http_status >= 400, 'STATUS_CODE_ERROR', 'STATUS_CODE_OK') AS StatusCode,
    multiIf(
        role = 'root',
        toJSONString(map('route', route, 'http.path', http_path, 'http.status', toString(http_status))),
        role = 'llm',
        toJSONString(map(
            'gen_ai.request.model', model,
            'gen_ai.response.model', model,
            'gen_ai.usage.input_tokens', toString(input_tokens),
            'gen_ai.usage.output_tokens', toString(output_tokens),
            'gen_ai.provider.name', provider,
            'agw.ai.usage.cost.total', toString((input_tokens * rate_in + output_tokens * rate_out) / 1000000.0),
            'agw.llm.custom_dimensions', concat(
                '[["organization","', organization, '"],["costCenter","', cost_center, '"],["businessUnit","', business_unit,
                '"],["team","', team, '"],["group","', grp, '"],["user","', usr, '"],["provider","', provider,
                '"],["model","', model, '"],["modelFamily","', model_family, '"],["virtualKey","', vkey,
                '"],["project","', project, '"],["environment","', environment, '"]]')
        )),
        toJSONString(map('gen_ai.tool.name', tool_name, 'mcp.target', mcp_server, 'mcp.resource.name', tool_name, 'mcp.resource.type', 'tool'))
    ) AS SpanAttributes
FROM
(
    SELECT
        number AS req,
        concat('${DEMO_TRACE_PREFIX}', substring(lower(hex(MD5(toString(number)))), 1, 24)) AS trace_id,
        substring(lower(hex(MD5(concat(toString(number), '-root')))), 1, 16) AS root_span,
        substring(lower(hex(MD5(concat(toString(number), '-llm')))), 1, 16) AS llm_span,
        llm_span AS tool_span_parent,
        now64(9) - toIntervalSecond(toInt64(rand() % (${LOOKBACK_DAYS} * 24 * 3600))) AS root_ts,
        ['demo-agentgateway','demo-checkout','demo-search','demo-support'][(intDiv(number, 5) % 4) + 1] AS service_name,
        ['/chat','/budget-demo','/openai','/search'][(number % 4) + 1] AS route,
        concat(route, '/v1/chat/completions') AS http_path,
        multiIf(number % 25 = 0, 429, number % 51 = 0, 500, 200) AS http_status,
        ['openai','openai','anthropic','anthropic','gcp.gemini'][(number % 5) + 1] AS provider,
        ['gpt-4o','gpt-4o-mini','claude-sonnet-4-5','claude-haiku-3-5','gemini-2.0-flash'][(number % 5) + 1] AS model,
        multiIf(model LIKE 'gpt-%', 'gpt', model LIKE 'claude-%', 'claude', model LIKE 'gemini-%', 'gemini', 'other') AS model_family,
        ['search_web','fetch_url','run_sql','summarize','get_weather','send_email','lookup_order','translate'][(number % 8) + 1] AS tool_name,
        ['mcp-tools','mcp-search','mcp-data'][(number % 3) + 1] AS mcp_server,
        ['alice','bob','carol','dave','eve','frank','grace','heidi'][(number % 8) + 1] AS usr,
        ['developers','developers','data-science','data-science','infra','infra','platform','platform'][(number % 8) + 1] AS grp,
        ['developers','developers','data-science','data-science','infra','infra','platform','platform'][(number % 8) + 1] AS team,
        ['platform','platform','ai-lab','ai-lab','ops','labs','applied-ai','apps'][(number % 8) + 1] AS business_unit,
        ['engineering','engineering','ml-platform','ml-platform','research','research','product','product'][(number % 8) + 1] AS cost_center,
        ['acme','acme','globex','globex','initech','wayne','stark','oscorp'][(number % 8) + 1] AS organization,
        ['vk-acme-prod','vk-acme-dev','vk-globex-ml','vk-globex-ml','vk-initech-ops','vk-wayne-labs','vk-stark-ent','vk-oscorp-dev'][(number % 8) + 1] AS vkey,
        ['checkout','search','copilot','forecasting','summaries','labs','agents','gateway'][(number % 8) + 1] AS project,
        ['prod','dev','prod','prod','dev','prod','dev','prod'][(number % 8) + 1] AS environment,
        toUInt64(200 + (rand() % 4000)) AS input_tokens,
        toUInt64(100 + (rand() % 2000)) AS output_tokens,
        [5.0, 0.15, 3.0, 0.8, 0.1][(number % 5) + 1]  AS rate_in,
        [15.0, 0.6, 15.0, 4.0, 0.4][(number % 5) + 1] AS rate_out,
        toUInt64(300000000 + (rand() % 2500000000)) AS dur_root,
        toUInt64(200000000 + (rand() % 2000000000)) AS dur_llm,
        toUInt64(20000000 + (rand() % 300000000))   AS dur_tool
    FROM numbers(${NUM_REQUESTS})
)
-- 2 spans per request (root+llm), plus a tool span on every 3rd request
ARRAY JOIN arrayConcat(['root', 'llm'], if(req % 3 = 0, ['tool'], [])) AS role
SETTINGS max_execution_time = 600
SQL

echo -e "${BLUE}Seeding the Virtual API Keys Secret (powers the Virtual API Keys tab)...${NC}"
"${KC[@]}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${VK_SECRET}
  namespace: ${NS}
  labels:
    agentgateway.solo.io/virtual-key-set: ${VK_SECRET}
type: Opaque
stringData:
  acme-prod:   '{"key":"sk-acme-prod-001","metadata":{"costCenter":"engineering","group":"developers","id":"vk-acme-prod","organization":"acme","user":"alice"}}'
  acme-dev:    '{"key":"sk-acme-dev-001","metadata":{"costCenter":"engineering","group":"developers","id":"vk-acme-dev","organization":"acme","user":"bob"}}'
  globex-ml:   '{"key":"sk-globex-ml-001","metadata":{"costCenter":"ml-platform","group":"data-science","id":"vk-globex-ml","organization":"globex","user":"carol"}}'
  initech-ops: '{"key":"sk-initech-ops-001","metadata":{"costCenter":"product","group":"infra","id":"vk-initech-ops","organization":"initech","user":"dave"}}'
  wayne-labs:  '{"key":"sk-wayne-labs-001","metadata":{"costCenter":"research","group":"platform","id":"vk-wayne-labs","organization":"wayne","user":"frank"}}'
  stark-ent:   '{"key":"sk-stark-ent-001","metadata":{"costCenter":"ml-platform","group":"data-science","id":"vk-stark-ent","organization":"stark"}}'
  oscorp-dev:  '{"key":"sk-oscorp-dev-001","metadata":{"costCenter":"product","group":"infra","id":"vk-oscorp-dev","organization":"oscorp","user":"eve"}}'
EOF

SUMMARY="$(ch -q "SELECT countMerge(request_count), round(toFloat64(sumMerge(spend_usd)), 2) FROM ${DB}.agw_cost_model_5m WHERE service_name LIKE 'demo-%' FORMAT TSV" 2>/dev/null)"
TRACES="$(ch -q "SELECT count() FROM ${DB}.otel_traces_json WHERE ServiceName LIKE 'demo-%'" 2>/dev/null | tr -d '[:space:]')"
REQS="$(echo "${SUMMARY}" | cut -f1)"; USD="$(echo "${SUMMARY}" | cut -f2)"
echo ""
echo -e "${GREEN}Seeded ~${REQS:-?} priced requests (\$${USD:-?} demo spend) as ${TRACES:-?} trace spans over the last ${LOOKBACK_DAYS} days.${NC}"
echo -e "${GREEN}Solo UI → Cost Management (per-model / per-org / per-user / virtual keys) AND the${NC}"
echo -e "${GREEN}Traces explorer are now populated. See 02-install-ui.sh / ui-login.sh for access.${NC}"
echo -e "${YELLOW}Re-run to reseed; run '$0 --cleanup' to remove the demo data.${NC}"
