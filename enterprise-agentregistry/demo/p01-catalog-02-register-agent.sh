#!/bin/bash
# Pillar 1 · Catalog & Discovery — Case 2: Register an agent (diceagent).
#
# What it shows
#   `arctl init agent` scaffolds an ADK/Python agent project (agent.py +
#   agent.yaml + Dockerfile). A single `arctl apply -f agent.yaml` then
#   registers the agent's declarative spec in the catalog — perfect
#   symmetry with p01-catalog-01's `arctl apply -f mcp.yaml`. Building +
#   loading the image is optional here (the catalog entry is the story);
#   p03-deploy-01 exercises the full build → deploy → chat round-trip.
#
# Steps
#   1. `arctl init agent diceagent --framework adk --language python \
#         --model-provider <gemini> --model-name <gemini-2.5-flash>`
#   2. Show the generated agent.yaml — narrative moment.
#   3. (Optional, Docker-gated) `arctl build ./diceagent` — build the image.
#   4. `arctl apply -f agent.yaml` — register in the catalog.
#   5. `arctl get agents` / `arctl get agent diceagent -o yaml` — confirm.
#   6. Cleanup: `arctl delete agent diceagent` + rm workdir.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

require_arctl
require_cmds jq

AGENT_NAME="diceagent"
WORKDIR="$(mktemp -d -t enterprise-ar-agent-XXXXXX)"
: "${DEMO_AGENT_MODEL_PROVIDER:=gemini}"
: "${DEMO_AGENT_MODEL_NAME:=gemini-2.5-flash}"

cleanup() {
  if [ "${DEMO_KEEP:-0}" = "1" ]; then
    demo_step "Cleanup — keeping ${AGENT_NAME} registered (DEMO_KEEP=1); removing workdir only"
    rm -rf "${WORKDIR}"
    return
  fi
  demo_step "Cleanup — deregistering agent + removing workdir"
  "${ARCTL}" delete agent "${AGENT_NAME}" 2>/dev/null || true
  rm -rf "${WORKDIR}"
}
trap 'cleanup; _cleanup_portforwards' EXIT

demo_header "Pillar 1 · Catalog & Discovery — Register an agent"

ensure_registry_portforward

demo_step "Scaffold a new ADK/Python agent with arctl init"
echo "  arctl init agent ${AGENT_NAME} \\"
echo "    --framework adk --language python \\"
echo "    --model-provider ${DEMO_AGENT_MODEL_PROVIDER} --model-name ${DEMO_AGENT_MODEL_NAME} \\"
echo "    --output-dir ${WORKDIR}"
prompt_continue "Run the init"
"${ARCTL}" init agent "${AGENT_NAME}" \
  --framework adk --language python \
  --model-provider "${DEMO_AGENT_MODEL_PROVIDER}" \
  --model-name "${DEMO_AGENT_MODEL_NAME}" \
  --output-dir "${WORKDIR}"

demo_step "Inspect the scaffolded project"
echo ""
echo -e "${CYAN}--- scaffold structure ---${NC}"
find "${WORKDIR}" -maxdepth 3 -type f 2>/dev/null | head -20
AGENT_YAML=$(find "${WORKDIR}" -name agent.yaml -type f 2>/dev/null | head -1)
AGENT_DIR=$(dirname "${AGENT_YAML:-${WORKDIR}}")
if [ -n "${AGENT_YAML}" ]; then
  show_file "${AGENT_YAML}"
fi
prompt_continue "Read the scaffolded manifest"

# ---- Optional image build (gated) -----------------------------------------
# Most catalog demos don't need a built image — the catalog entry is the
# story. Opt in with DEMO_DOCKER_REGISTRY_PUSHABLE=1 + a reachable Docker.
if [ "${DEMO_DOCKER_REGISTRY_PUSHABLE:-0}" = "1" ] && docker info >/dev/null 2>&1; then
  demo_step "Building the agent image (optional)"
  echo "  arctl build ${AGENT_DIR}"
  prompt_continue "Run the build"
  "${ARCTL}" build "${AGENT_DIR}" \
    || echo -e "${YELLOW}  (build failed — catalog registration below still works)${NC}"
else
  echo ""
  echo -e "${CYAN}Skipping image build (set DEMO_DOCKER_REGISTRY_PUSHABLE=1 + run Docker to include it).${NC}"
  echo -e "${CYAN}Applying the agent.yaml below catalogs the spec; p03-deploy-01 does the full build → deploy.${NC}"
fi

demo_step "Register the agent into the catalog (arctl apply)"
echo "  arctl apply -f ${AGENT_YAML}"
prompt_continue "Run the apply"
"${ARCTL}" apply -f "${AGENT_YAML}"

demo_step "List registered agents"
echo "  arctl get agents"
"${ARCTL}" get agents

demo_step "Show the stored spec for the registered agent"
echo "  arctl get agent ${AGENT_NAME} -o yaml"
prompt_continue
"${ARCTL}" get agent "${AGENT_NAME}" -o yaml 2>&1 \
  || echo -e "${YELLOW}  (try -o json or check 'arctl get --help')${NC}"

prompt_continue "Demo complete — press Enter to clean up"
