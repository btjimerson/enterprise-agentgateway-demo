# Agentic demos

Demos for Solo Enterprise products, each one self-contained and runnable on a
Kubernetes cluster you bring.

| Demo | What it shows |
|---|---|
| [`enterprise-agentgateway/`](enterprise-agentgateway/) | Solo Enterprise for Agentgateway: LLM routing, MCP and A2A agent workflows, security and governance, observability, self-hosted models. |
| [`enterprise-agentregistry/`](enterprise-agentregistry/) | Solo Enterprise for Agentregistry with kagent: a governed catalog of agents and MCP servers, OIDC and RBAC, deployment to runtimes. |

Shared pieces live at the top level:

- [`common/`](common/): shell helpers sourced by every demo's scripts.
- [`keycloak/realm-demo.json`](keycloak/realm-demo.json): the Keycloak realm both demos use. It
  holds no secrets; every secret is a `${VAR}` placeholder that Keycloak fills from its own
  environment at import time. Keycloak is not installed by these demos.

Start with a demo's own README. Each one has an `.envrc.sample` to copy to `.envrc`, an
`install-all.sh`, numbered demo scripts under `demo/`, and a `cleanup-all.sh`. The two demos
can be installed into the same cluster.
