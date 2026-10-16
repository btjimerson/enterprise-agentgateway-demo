# Solo Enterprise for Agentregistry — end-to-end demo

Targets the **agentregistry** release pinned as `AGENTREGISTRY_VERSION` in
[`.envrc.sample`](.envrc.sample). A complete, self-
contained demo that stands up the Enterprise Agentregistry control plane
alongside Solo Enterprise for kagent, registers agents + MCP servers with
OIDC / RBAC, and deploys registered agents to the supported targets
(in-cluster kagent, plus optional AWS Bedrock). Built from the
official quickstart: https://docs.solo.io/agentregistry/latest/quickstart/kagent/

See [`architecture.md`](architecture.md) for the component + data-flow diagrams.

> **Coverage gaps:** the demos and behavioral notes (RBAC verbs, audit scope, cloud
> deploy) predate the current pin and still need re-verification against it. Two
> things to fold in: **OTLP control-plane audit events** (the demo doesn't consume
> them yet), and Microsoft **Copilot Studio** as a discovery source alongside
> Foundry/Bedrock. The **"shadow existing CSP agents" discovery** story still
> headlines: register a provider Runtime and the registry's syncer lists its
> existing agents as Unmanaged instances. Wired here for **Microsoft Foundry**
> (`p01-discover-01-foundry.sh`) and **AWS Bedrock AgentCore** (`05` + the Bedrock
> note below).

> Abbreviation: the directory + env prefix is **`enterprise-ar`**
> (never `are` or `agentregistry` on their own). Keeps shell history
> and logs searchable.

## Prerequisites

- A Kubernetes cluster:
  - **GKE** (or any cloud with LoadBalancer support) — set `CLUSTER_TYPE=gke`.
  - **kind** — set `CLUSTER_TYPE=kind`, and run
    [`cloud-provider-kind`](https://github.com/kubernetes-sigs/cloud-provider-kind)
    on the host so LoadBalancer Services get IPs.
- An **external Keycloak 26** that you run, reachable over public HTTPS. This demo has
  no in-cluster Keycloak — import the realm in
  [`../keycloak/realm-demo.json`](../keycloak/realm-demo.json) (clients, groups and demo
  users; see the Keycloak section of the
  [`enterprise-agentgateway` README](../enterprise-agentgateway/README.md)) and set
  `KEYCLOAK_EXTERNAL_URL` in `.envrc` to its hostname. Start Keycloak with
  `SOLO_UI_BACKEND_SECRET`, `AR_BACKEND_SECRET`, `KAGENT_BACKEND_SECRET` and the
  `DEMO_USER_*_PASSWORD` values set to the same values as in your `.envrc`.
  `02-install-kagent.sh` and `03-install-agentregistry.sh` probe that issuer's OIDC
  discovery endpoint before installing, so a placeholder or unreachable host fails in
  a second rather than as a confusing runtime error later. Note that **editing
  `.envrc` revokes direnv's allow** — run `direnv allow` after any edit.
  `SOLO_SKIP_ISSUER_CHECK=1` bypasses the probe.
- `helm`, `kubectl`, `direnv`, `jq`, `curl`, `openssl`, Docker.
- `arctl` is **auto-installed** by `04-install-arctl.sh` (official installer,
  pinned to `$ARCTL_VERSION`) into `~/.arctl/bin`. Set `ARCTL_BIN` to override
  with your own binary.
- A Solo Enterprise **kagent** license key (`KAGENT_LICENSE_KEY`). The
  agentregistry chart + image are **public** — no license needed for
  the registry itself.
- `OPENAI_API_KEY` (the kagent controller's built-in k8s-agent) and
  `GOOGLE_API_KEY` (the demo `gemini-2.5-flash` agent — needed for deploy + chat).

## Quick start

```shell
cp .envrc.sample .envrc
# edit .envrc — paste KAGENT_LICENSE_KEY, OPENAI_API_KEY, GOOGLE_API_KEY;
# set CLUSTER_TYPE=gke|kind
direnv allow
./install-all.sh
```

Roughly 5–8 min wall-clock. The registry Service is ClusterIP, so `arctl` needs
a port-forward, and `arctl`'s own login session isn't refreshable here — so use
the **`arctl.sh`** wrapper, which opens the port-forward and mints a fresh bearer
token per call:

```shell
./arctl.sh get runtimes
./demo/p01-catalog-01-register-mcp.sh          # demos open their own forward + mint their own tokens
./demo/p02-security-02-rbac-reader-vs-writer.sh
./demo/p03-deploy-01-kagent-k8s.sh
```

> `./arctl.sh <args>` is a thin wrapper around `./bin/arctl` — same commands, but
> it guarantees a port-forward + a valid token every time. Use `./bin/arctl`
> directly only if you've set up your own forward + `ARCTL_API_TOKEN`.

**Populate the catalog with demo data.** A fresh registry has the runtimes but
an empty catalog. To browse a realistic set of entries in the UI and `arctl`
without building or pulling anything, seed a synthetic catalog (12 agents + 10
MCP servers, all `demo-` prefixed):

```shell
./seed-registry-data.sh              # arctl apply -f manifests/seed-catalog.yaml
./seed-registry-data.sh --cleanup    # remove the demo catalog
```

The registry stores the declarative specs only; `localhost:5001/*` image refs
are exempt from OCI-label validation, so nothing is fetched. Idempotent —
re-run any time.

Full teardown:

```shell
./cleanup-all.sh
```

> **Co-installing with `enterprise-agentgateway` in the same cluster** is
> supported. Both demos point at the **same external Keycloak realm**, so there is no
> in-cluster IdP to collide on, and `cleanup-all.sh` here leaves Keycloak untouched.
> Both demos do still install the `management` chart, which ships fixed-name
> cluster-scoped singletons only one Helm release can own — the management CRDs and
> the `solo-enterprise-ui` ClusterRole/ClusterRoleBinding.
> `02-install-kagent.sh` auto-detects an existing `management` release
> (order-independent) and installs ours with `management-crds.enabled=false`
> (share the CRDs) **and** `kubernetes.watchNamespaces={…}` (namespaced UI RBAC
> over our own namespaces instead of the cluster-scoped ClusterRole). The
> first/only release keeps the default cluster-wide UI; the second-installed
> release's UI is scoped to its watched namespaces. Cleanup hands the shared
> CRDs to the surviving release rather than deleting them. The `management`
> (Solo UI) chart is versioned by **`UI_MANAGEMENT_VERSION`** here too — the
> same variable the agentgateway demo uses — defaulting to
> `KAGENT_ENT_VERSION` if unset (so kagent + UI stay in lockstep). Set
> `UI_MANAGEMENT_VERSION` (and `UI_RBAC_MODE`) to the same value in both demos so the
> shared `management` CRDs match, since the first to install owns the schema; after
> tearing down both, a few `*.solo.io` management CRDs may linger and can be
> deleted manually. Agentregistry has **no page** in the pinned management frontend
> (`KAGENT_ENT_VERSION`) — browse the catalog via the registry's own UI
> (`svc/agentregistry-enterprise-server:12121`, as `ui-login.sh` prints).

## Platform only, no configuration

To stand up the platform and nothing else — no registered Runtimes and no catalog
data:

```bash
./install-infra.sh
```

Runs `02`, `03`, `04`: Solo Enterprise for kagent, the Agentregistry server, and the
`arctl` CLI. Pairs with `./cleanup-infra.sh`.

Use it to test an upgrade, reproduce a customer issue against a clean registry, or
build your own configuration on top. **The demo scripts under `demo/` will not work
after this.** A Runtime is a named deployment target and every deploy demo
references one by name via a Deployment's `runtimeRef`, so with none registered
there is nothing to deploy to. Add the layers when you want them:

```bash
./05-register-runtimes.sh       # kagent (+ AWS / Foundry if the env vars are set)
./seed-registry-data.sh         # catalog content
```

`cleanup-infra.sh` removes only the platform. Registered Runtimes and catalog
content live in the registry's own database, so destroying the platform takes them
with it — but without running `05-register-runtimes.sh --cleanup` first, any
external state it created is left behind. The script detects registered Runtimes
and warns, pointing at `cleanup-all.sh`.

## Layout

```
enterprise-agentregistry/
├── .envrc.sample                   # env knobs (license/API keys, versions, CLUSTER_TYPE)
├── README.md                       # this file
├── architecture.md                 # component + data-flow diagrams
├── install-all.sh                  # orchestrator — runs 02 → 05
├── arctl.sh                        # wrapper: open registry port-forward + mint fresh token, then run arctl
├── cleanup-all.sh                  # orchestrator — reverses 02 ← 05
├── ui-login.sh                     # port-forward the registry catalog UI (:12121) + management/kagent UI (:4000)
├── seed-registry-data.sh           # seed a synthetic catalog (12 agents + 10 MCP servers) for the UI/demos; --cleanup
├── 02-install-kagent.sh            # 3 charts: management + kagent-crds + kagent (KAGENT_ENT_VERSION)
├── 03-install-agentregistry.sh     # registry chart (AGENTREGISTRY_VERSION) with native OIDC values
├── 04-install-arctl.sh             # install arctl + password-credentials login
├── 05-register-runtimes.sh         # kagent Runtime + optional AWS/Foundry (wires AWS creds + region onto the registry)
├── manifests/
│   ├── agentregistry/values.yaml
│   ├── management/values.yaml
│   ├── kagent/values.yaml
│   └── kagent/rolebinding-agentregistry-writer.yaml
└── demo/                           # 13 demo cases across 5 pillars
    ├── _common.sh                  # shared helpers (port-forwards, arctl_as, arctl_apply)
    ├── p01-catalog-01-register-mcp.sh
    ├── p01-catalog-02-register-agent.sh
    ├── p01-catalog-03-discover-via-ui.sh
    ├── p01-catalog-04-arctl-search.sh
    ├── p01-discover-01-foundry.sh       # shadow existing Microsoft Foundry agents (optional)
    ├── p02-security-01-oidc-login.sh
    ├── p02-security-02-rbac-reader-vs-writer.sh
    ├── p02-security-03-audit-log.sh
    ├── p03-deploy-01-kagent-k8s.sh
    ├── p03-deploy-02-aws-bedrock.sh
    ├── p04-integration-01-agentgateway-pull.sh
    ├── p04-integration-02-unified-ui.sh
    └── p05-obs-01-audit-insights.sh
```

## Demo cases

| # | Pillar                     | Script                                   | What it shows |
|---|----------------------------|------------------------------------------|---|
| 1 | Catalog & Discovery        | `p01-catalog-01-register-mcp.sh`             | Scaffold + `arctl apply` an MCP server into the catalog. |
| 2 | Catalog & Discovery        | `p01-catalog-02-register-agent.sh`           | Scaffold + `arctl apply` an ADK/Python agent. |
| 3 | Catalog & Discovery        | `p01-catalog-03-discover-via-ui.sh`          | Browser walkthrough of the registry web UI (`:12121`). |
| 4 | Catalog & Discovery        | `p01-catalog-04-arctl-search.sh`             | CLI discovery (`arctl get mcp` / `get agents`). |
| 4a| Catalog & Discovery        | `p01-discover-01-foundry.sh`                 | Shadow agents already running in **Microsoft Foundry** as Unmanaged instances (discovery-only, optional). |
| 5 | Secure Access              | `p02-security-01-oidc-login.sh`              | OIDC login via Keycloak; 401-vs-authed; decode the JWT `Groups` claim. |
| 6 | Secure Access              | `p02-security-02-rbac-reader-vs-writer.sh`   | RBAC: admin (superuser) vs writer vs reader via group claims. |
| 7 | Secure Access              | `p02-security-03-audit-log.sh`               | Audit trail from registry logs / telemetry. |
| 8 | Multi-Cloud Deploy         | `p03-deploy-01-kagent-k8s.sh`                | Deploy a published agent to in-cluster kagent (declarative `Deployment`). |
| 9 | Multi-Cloud Deploy         | `p03-deploy-02-aws-bedrock.sh`               | Same agent, AWS Bedrock Runtime (optional). |
| 10| Integration                | `p04-integration-01-agentgateway-pull.sh`    | The gRPC surface (`:21212`) agentgateway consumes. |
| 11| Integration                | `p04-integration-02-unified-ui.sh`           | Solo Enterprise UI alongside the registry catalog. |
| 12| Observability              | `p05-obs-01-audit-insights.sh`               | ClickHouse-backed telemetry queries. |

> **AWS Bedrock discovery (shadowing existing AgentCore agents).** Distinct from
> `p03-deploy-02`'s deploy path (a non-functional stub):
> registering the AWS Bedrock Runtime makes the registry's syncer auto-list agents
> already running in AgentCore as **Unmanaged** instances. It needs (a) the registry
> to hold AWS credentials and (b) a `region` on the Runtime — both handled by
> `05-register-runtimes.sh` once you set `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
> (+ `AWS_REGION`, default `us-east-1`) alongside the `AWS_PROVIDER_*` knobs in
> `.envrc`. Since the registry runs in-cluster (no EC2 instance role), without the
> credentials these calls fail with `no EC2 IMDS role found`.

> **Microsoft Foundry discovery (`p01-discover-01-foundry.sh`).** New `MicrosoftFoundry`
> Runtime type — **discovery-only** (the registry never deploys to
> Foundry; create the agent in Foundry first). Auth is the Entra client-credentials
> flow (scope `https://ai.azure.com/.default`); the registry lists
> `{projectEndpoint}/agents?api-version=v1` and shows them as Unmanaged instances.
> Set `AZURE_FOUNDRY_TENANT_ID` / `AZURE_FOUNDRY_CLIENT_ID` /
> `AZURE_FOUNDRY_CLIENT_SECRET` / `AZURE_FOUNDRY_PROJECT_ENDPOINT` in `.envrc`;
> `05` stores the secret via the registry Secret API and registers the Runtime.
> Azure prereqs (Entra app, a Foundry **project** endpoint, **Foundry User** RBAC
> on the project, ≥1 agent) are in the script header.

## Out of scope for this build

Not covered by this build:

- A2A agent-to-agent discovery
- GitOps via CRDs
- Cross-cluster federation
- Semantic search (pgvector + embeddings)

The unified-UI integration depth and the kagent deploy session bridge should
be re-verified against the pinned management/kagent charts
(`KAGENT_ENT_VERSION`) during the run (p04-integration-02, p03-deploy-01).
