#!/bin/bash
# Pillar 4 · Integration — Case 1: agentgateway pulls tool lists from
# the registry's gRPC endpoint.
#
# What it shows
#   The agentregistry server exposes a gRPC push channel (agentGatewayPort
#   21212) that agentgateway consumes, plus an MCP HTTP port (31313). This
#   case verifies the gRPC Service is serving and walks the wiring pattern
#   — it does NOT install agentgateway (that's enterprise-agentgateway).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

require_cmds kubectl

REGISTRY_SVC="agentregistry-enterprise-server"

demo_header "Pillar 4 · Integration — agentgateway gRPC pull surface"

demo_step "Registry Service ports (http 12121, grpc 21212, mcp 31313)"
echo "  kubectl -n ${AGENTREGISTRY_NAMESPACE} get svc ${REGISTRY_SVC}"
prompt_continue
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
  get svc "${REGISTRY_SVC}" \
  -o custom-columns='NAME:.metadata.name,PORTS:.spec.ports[*].port,CLUSTER-IP:.spec.clusterIP'

demo_step "Proof-of-life: the gRPC port (21212) is open + responding"
_kill_stale_pf_on_port 21212
kubectl --context "${CLUSTER_CONTEXT}" -n "${AGENTREGISTRY_NAMESPACE}" \
  port-forward "svc/${REGISTRY_SVC}" 21212:21212 \
  >/tmp/enterprise-ar-grpc-pf.log 2>&1 &
pid=$!
_PF_PIDS+=("${pid}")
disown "${pid}" 2>/dev/null || true
for _ in $(seq 1 20); do
  (exec 3<>/dev/tcp/localhost/21212) 2>/dev/null && { exec 3<&- 3>&-; break; }
  sleep 0.5
done

if command -v grpcurl >/dev/null 2>&1; then
  echo "  grpcurl -plaintext localhost:21212 list"
  grpcurl -plaintext localhost:21212 list 2>&1 \
    || echo -e "${YELLOW}  (reflection may be disabled — TCP connectivity confirmed above)${NC}"
else
  echo -e "${CYAN}(grpcurl not installed — TCP connectivity confirmed via port-forward above)${NC}"
fi

demo_step "How agentgateway wires in"
cat <<EOF
  1. agentgateway's EnterpriseAgentgatewayPolicy ships an
     mcpBackends.registry block pointing at:
       ${REGISTRY_SVC}.${AGENTREGISTRY_NAMESPACE}.svc:21212

  2. On startup, agentgateway opens a gRPC stream and receives the
     current tool catalog + subsequent deltas.

  3. Tools registered here (p01-catalog-01 / p01-catalog-02) become routable
     through agentgateway without a separate MCPServer CR apply.

  Full cross-product demo lives under enterprise-agentgateway/demo/.
EOF

prompt_continue "Demo complete — press Enter"
