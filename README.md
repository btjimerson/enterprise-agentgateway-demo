<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
# Contents

- [Solo Enterprise for Agentgateway — Demo](#solo-enterprise-for-agentgateway--demo)
  - [Prerequisites](#prerequisites)
  - [Environment](#environment)
  - [Install — infrastructure only](#install--infrastructure-only)
    - [Platform only, no configuration](#platform-only-no-configuration)
  - [Upgrading an existing install](#upgrading-an-existing-install)
  - [Validation](#validation)
  - [Demo cases](#demo-cases)
  - [Cleanup](#cleanup)
  - [Notes & scope](#notes--scope)
  - [Layout](#layout)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

# Solo Enterprise for Agentgateway — Demo

A single-cluster, self-contained demo of Solo Enterprise for Agentgateway
covering the nine customer capability pillars:

1. Unified AI Control Plane
2. Intelligent LLM Routing & Optimization
3. Multi-Agent & Tool Workflows (A2A + MCP)
4. Split-Plane Architecture
5. Security & Governance
6. Scalable, Multi-Cloud Deployment *(told narratively — see note below)*
7. Observability & Auditability
8. Model Feature Controls & API Flexibility
9. Self-Hosted Models

See [architecture.md](architecture.md) for the component diagram.

## Prerequisites

- An existing Kubernetes cluster you can reach with your current
  `kubectl` context. EKS/GKE/AKS/kind all work.
- `kubectl`, `helm` 3.x, `curl`, `jq`, `direnv`.
- A Solo Enterprise for Agentgateway license key.
- An OpenAI API key (the primary provider). Any account with access to
  `gpt-4o` will do.

## Environment

```bash
cd enterprise-agentgateway-demo
cp .envrc.sample .envrc
# Edit .envrc: paste AGENTGATEWAY_LICENSE_KEY and OPENAI_API_KEY, and choose
# SOLO_UI_BACKEND_SECRET + the demo-user passwords (see "Keycloak" below)
direnv allow
```

## Install — infrastructure only

Every script is idempotent (`helm upgrade -i`) and supports `--cleanup`.
**No demo policies are applied by install** — each demo script owns the
policy it demonstrates.

| # | Script | Namespace(s) | What it does |
|---|---|---|---|
| 1 | `./01-install-agentgateway.sh` | `agentgateway-system` | Gateway API CRDs + Enterprise Agentgateway CRDs + control plane (2 replicas) + data-plane `Gateway/agentgateway-proxy` |
| 2 | `./02-install-ui.sh`           | `agentgateway-system` | Solo Enterprise UI (`management` chart) — `solo-enterprise-ui`, telemetry collector, ClickHouse, plus the baseline `tracing` policy the UI needs to ingest traces |
| 3 | `./03-install-observability.sh`| `monitoring`          | OTel collector + Prometheus + Grafana with pre-loaded agentgateway dashboards |
| 5 | `./05-install-eso.sh`          | `external-secrets`, `agentgateway-system` | External Secrets Operator + fake `ClusterSecretStore` + `openai-secret` |
| 6 | `./06-install-llm-backends.sh` | `agentgateway-system`, `agentgateway-demo` | OpenAI + mock-llm `AgentgatewayBackend`s; multi-provider priority group; `/chat` HTTPRoute |
| 7 | `./07-install-mcp-agents.sh`   | `agentgateway-demo`   | Two `mcp-server-everything` instances + `a2a-agent`; `mcp-federated` backend; `/mcp` and `/a2a` HTTPRoutes |
| 8 | `./08-install-admin-ingress.sh`| `agentgateway-system` | Second `Gateway` (`admin-proxy`) with listeners 3000/4000/7777 → Grafana / UI / STS. One LoadBalancer replaces a port-forward tab per service. Does not expose Keycloak — that is the shared external server |
| 9 | `./09-install-obo.sh`          | `agentgateway-system`, `agentgateway-demo` | Flips on `tokenExchange` in the control plane (RFC 8693 STS), deploys `agent-sa`, and adds a 4th listener (`sts`:7777) + HTTPRoute on `admin-proxy` |
| 10 | `./10-install-elicitation.sh` | `agentgateway-system` | *(optional)* URL-mode OAuth **elicitation** wiring on the control + data plane (STS `CALLBACK_URL`, remote API validator, single STS replica) — the one-time setup `demo/p05-security-05-elicitation-github.sh` assumes. **Self-skips** unless `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` are set, so it never blocks a base install |

One-liner for the happy path:

```bash
./install-all.sh
```

(Runs `01`, `02`, `03`, `05`, `06`, `07`, `08`, `09`, `10` in order — there is
no `04`; Keycloak is the shared external server, see below — and stops on the
first failure. Pairs with `./cleanup-all.sh` for teardown.)

### Platform only, no configuration

To stand up the platform and nothing else — no LLM backends, routes, MCP or A2A
workloads, and no token-exchange or elicitation wiring:

```bash
./install-infra.sh
```

Runs `01`, `02`, `03`, `05`, `08`: control plane, Solo UI, observability, ESO, and
the admin ingress Gateway. Pairs with `./cleanup-infra.sh`.

Use it to test an upgrade, reproduce a customer issue against a clean gateway, or
build your own configuration on top. **The demo scripts under `demo/` will not
work after this** — they assume the backends and routes from `06` and the
workloads from `07`. Add those layers individually when you want them:

```bash
./06-install-llm-backends.sh    # backends + /chat + /vllm routes + mock LLMs
./07-install-mcp-agents.sh      # MCP + A2A workloads
./09-install-obo.sh             # token exchange / STS
./10-install-elicitation.sh     # elicitation wiring
```

`cleanup-infra.sh` removes only the platform. If configuration layers are present
it warns and points at `cleanup-all.sh`, because tearing out the control plane
underneath live backends and routes leaves them orphaned rather than clean.

**Keycloak is not installed by this demo — you bring your own.** Run Keycloak 26
anywhere that is reachable over **public HTTPS** from both your browser and the
cluster (an in-cluster Keycloak over plain HTTP cannot satisfy both the browser
and the in-cluster UI backend with one issuer), then import the realm in
[`keycloak/realm-agentgateway-demo.json`](keycloak/realm-agentgateway-demo.json):
realm `solo`, clients `agw-client` / `solo-ui-frontend` / `solo-ui-backend`,
users `alice` / `bob`. The file contains no secrets — it uses `${VAR}`
placeholders that Keycloak fills from its own environment at import time, so
start Keycloak with `SOLO_UI_BACKEND_SECRET`, `DEMO_USER_ALICE_PASSWORD` and
`DEMO_USER_BOB_PASSWORD` set to the same values as in your `.envrc`:

Mount the file into the container's import directory and start Keycloak with
`--import-realm` (Keycloak's documented path for `${VAR}` substitution):

```bash
# docker-compose / podman: -v ./keycloak/realm-agentgateway-demo.json:/opt/keycloak/data/import/realm.json:ro
# command: start --import-realm
```

`--import-realm` only imports into an **empty** realm: if a realm named `solo`
already exists, delete it (or use a fresh database) first.

Redirect URIs in the realm are restricted to `localhost`; add your own if you
log in to the UI from anywhere else. Point the demo at Keycloak with
`KEYCLOAK_EXTERNAL_URL` in `.envrc`.

## Upgrading an existing install

Bumping `AGENTGATEWAY_VERSION` and re-running `./01-install-agentgateway.sh` upgrades
the control plane, but it is **not** sufficient on its own:

1. **Re-run `09-install-obo.sh` and `10-install-elicitation.sh` afterward.** Both layer
   their config onto the agentgateway release with `helm upgrade --reuse-values`. A
   plain re-run of `01` resets those values, which silently removes the `tokenExchange`
   block and stops exposing the STS on port 7777. The symptom is
   `p05-security-03-obo.sh` failing with `Failed to connect to localhost port 17777`,
   which looks like a port-forward problem and is not one. Verify with:

   ```bash
   helm get values enterprise-agentgateway -n agentgateway-system | grep -i tokenExchange
   ```

2. **Give the data-plane proxy time to roll.** `01` upgrades the controller; the
   controller then reconciles the `agentgateway-proxy` Deployment to the matching image.
   That took roughly 45 seconds in practice, so a proxy still reporting the old tag
   immediately after the Helm upgrade is normal. Confirm both moved before testing:

   ```bash
   kubectl -n agentgateway-system get deploy enterprise-agentgateway agentgateway-proxy \
     -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
   ```

3. **Check the compatibility matrix before bumping the UI.** `UI_MANAGEMENT_VERSION` is
   pinned to what the matrix pairs with the agentgateway release, not to the newest tag
   in the registry — the two are not the same thing. See
   <https://docs.solo.io/agentgateway/latest/reference/versions/>.

## Validation

```bash
kubectl -n agentgateway-system get pods,gateway,httproute,agentgatewaybackend
kubectl -n agentgateway-demo   get pods,svc
kubectl -n monitoring          get pods,svc
```

After install, the only `EnterpriseAgentgatewayPolicy` in the cluster is
the baseline `tracing` policy (Solo UI prerequisite). Every other policy
is applied and reverted by its owning demo script.

## Demo cases

27 scripts under `demo/` (excluding `_common.sh`; anything under
`demo/deprecated/` is not part of the demo set). Each follows
**show → apply → test → revert**:
prints the policy YAML, applies the manifest, runs the test, and deletes
the manifest on exit via a `trap`. Most are interactive (`Press Enter
to continue`); set `DEMO_AUTO=1` to skip prompts.

| Pillar | Case | Script | Effect |
|---|---|---|---|
| **2 · LLM Routing** | Happy-path chat | `demo/p02-routing-01-happy-path.sh`      | POST `/chat` with a JWT; OpenAI answers |
|                     | Multi-provider failover | `demo/p02-routing-02-failover.sh`        | health-retry policy + broken primary → failover to mock-llm |
|                     | Rate limit     | `demo/p02-routing-03-ratelimit.sh`       | 5 req/min per `x-user-id` → 429 after overflow |
|                     | ~~Prompt caching~~ **(deprecated)** | `demo/deprecated/prompt-caching.sh` | **Not part of the demo set** — cut because nothing was observable. Kept for reference; refuses to run without `RUN_DEPRECATED_DEMO=1` |
|                     | Weighted load balancing | `demo/p02-routing-05-weighted-split.sh`  | 80/20 split across openai + mock-llm via weighted backendRefs |
|                     | Content-based routing   | `demo/p02-routing-06-content-based-routing.sh` | `x-model` header switches backend |
|                     | Prompt enrichment       | `demo/p02-routing-07-prompt-enrichment.sh` | Prepend a system message via `backend.ai.promptEnrichment` |
|                     | Per-user token rate limit | `demo/p02-routing-08-token-rate-limit.sh`  | 300 tokens/min per `x-user-id` on `/token-rate` → 429 when spent |
|                     | Response header modification | `demo/p02-routing-09-transformations.sh`   | add `x-served-by`, strip upstream `x-request-id` |
|                     | Spend budgets           | `demo/p02-routing-10-spend-budget.sh`      | `EnterpriseAgentgatewayBudget` (USD Audit + 2000-token Block) + `entBudgetEnforcement` → 429 over budget; control route untouched |
|                     | Claude Code passthrough | `demo/p02-routing-11-claude-code-passthrough.sh` | Anthropic backend with **no pinned model** (passthrough) + Messages API; the model-header trick (`x-requested-model`/`x-actual-model`) + proxy logs prove the client's model is honored; prints how to point Claude Code at the gateway (`ANTHROPIC_BASE_URL`). `AUTH_MODE=oauth` (default) = Claude subscription via SSO (no key, token passed through); `AUTH_MODE=apikey` = needs `ANTHROPIC_API_KEY`. `DEMO_KEEP=1` leaves it wired up |
| **3 · Multi-Agent** | MCP multiplexing | `demo/p03-agents-01-mcp-multiplexing.sh` | `tools/list` returns union of two MCP servers |
|                     | MCP tool RBAC    | `demo/p03-agents-02-mcp-rbac.sh`         | alice sees restricted tool set; bob sees all |
|                     | A2A task         | `demo/p03-agents-03-a2a.sh`              | `tasks/send` to echo agent through `/a2a` |
|                     | MCP rate limit   | `demo/p03-agents-04-mcp-ratelimit.sh`    | 5 `tools/list` per user per min → 429 |
|                     | MCP Search mode  | `demo/p03-agents-05-mcp-search-mode.sh`  | `tools/list` shows only `get_tool`/`invoke_tool`; discover + call on demand |
|                     | MCP Code mode    | `demo/p03-agents-06-mcp-code-mode.sh`    | `tools/list` shows only `run_code`; JS runs in a sandbox, only the projection returns |
|                     | Composable MCP   | `demo/p03-agents-07-mcp-composable.sh`   | one `github-summary` tool assembled from 2 HTTP steps + CEL, no custom server |
| **5 · Security**    | JWT auth required | `demo/p05-security-01-jwt.sh`           | 401 without bearer, 200 with valid Keycloak JWT |
|                     | Prompt Guard      | `demo/p05-security-02-promptguard.sh`   | 403 on PII + prompt-injection content |
|                     | RFC 8693 OBO      | `demo/p05-security-03-obo.sh`           | User + SA tokens exchanged for a delegated token with `act` claim |
|                     | CEL-based /chat RBAC | `demo/p05-security-04-chat-rbac.sh`  | Deny-by-JWT-claim on `/chat` (alice denied, bob allowed) |
|                     | WAF (OWASP CRS)   | `demo/p05-security-06-waf.sh`           | 403 on SQLi/XSS inside the prompt body + LFI in the URI; benign prompt still 200 |
| **7 · Observability** | Grafana dashboards | `demo/p07-observability-01-grafana.sh` | Generate load, port-forward Grafana at :3000 |
| **8 · Model Controls** | Disable tool calling | `demo/p08-modelcontrols-01-tool-disable.sh` | `ai.overrides` strips `tools`/`tool_choice` pre-upstream |
| **9 · Self-Hosted Models** | vLLM fleet routing | `demo/p09-selfhosted-01-vllm-routing.sh` | One `/vllm` endpoint, two fleets by `x-model` header; a policy attached per **AgentgatewayBackend** injects a different system prompt per fleet |
|                     | Guardrails on LLM traffic | `demo/p09-selfhosted-02-vllm-guardrails.sh` | Baseline first, then `promptGuard` regex — request `Reject` (SSN/credential/classification → 422 with a custom message) and response `Mask` (email → `<EMAIL_ADDRESS>`) |
|                     | Virtual keys + audit trail | `demo/p09-selfhosted-03-vllm-identity-audit.sh` | SHA-256 key hashes in a labeled ConfigMap → `apiKeyAuthentication`; `frontend.accessLog` CEL attributes attribute every call — denials included — to a real identity |

Pillars 1 / 4 / 6 have no script of their own: the control plane, split-plane
architecture and multi-cloud portability are properties of the install itself.

Pillar 9 targets teams already self-hosting models behind an open-source AI
gateway.

Example:

```bash
./demo/p05-security-01-jwt.sh
# interactive — press Enter at each step; policy is removed on exit

DEMO_AUTO=1 ./demo/p02-routing-03-ratelimit.sh
# non-interactive (CI friendly)
```

## Cleanup

```bash
./cleanup-all.sh
```

Or one component at a time, in reverse order:

```bash
./10-install-elicitation.sh     --cleanup
./09-install-obo.sh             --cleanup
./08-install-admin-ingress.sh   --cleanup
./07-install-mcp-agents.sh      --cleanup
./06-install-llm-backends.sh    --cleanup
./05-install-eso.sh             --cleanup
./03-install-observability.sh   --cleanup
./02-install-ui.sh              --cleanup
./01-install-agentgateway.sh    --cleanup
```

## Notes & scope

- **Multi-cloud is not demonstrated live.** The customer pillar "Scalable,
  Multi-Cloud Deployment" is addressed by "same YAML runs
  on any cluster in any cloud". This demo does **not** stand up AWS +
  Azure + GCP clusters — swap `CLUSTER_CONTEXT` in `.envrc` and re-run to
  demo a second cloud.
- **Vault integration is represented by ESO.** `manifests/eso-fake-store.yaml`
  uses the ESO fake provider for portability; swap the `ClusterSecretStore`
  to a real Vault with no other manifest changes.
- **Second LLM provider** is `mock-llm` (a local HTTP service) to avoid
  requiring a second paid API key. Swap the second entry in
  `manifests/agentgatewaybackend-multi.yaml` for Anthropic or Bedrock to
  exercise cross-provider behavior.
- **Model override vs. passthrough.** An `AgentgatewayBackend`'s
  `spec.ai.provider.<provider>.model` is an *upstream override*: set it and the
  gateway forces (and, for Anthropic, rejects a mismatched) model regardless of
  what the client sent; **omit it and the client's model is passed through**. The
  Claude Code demo (`p02-routing-11`) uses an empty `anthropic: {}` passthrough
  backend + the Messages API route so a client like Claude Code can switch models
  freely — proven with the `x-requested-model`/`x-actual-model` header trick and
  the proxy's `gen_ai.request.model` logs. Point Claude Code at it with
  `ANTHROPIC_BASE_URL=http://<gateway>:8080/claude`. Two auth modes: a **Claude
  subscription via SSO** (the default `AUTH_MODE=oauth`) uses no
  `auth` block, so the gateway passes Claude Code's OAuth token straight through
  (plus a 10 MB buffer the OAuth flow needs) and no API key is set; `AUTH_MODE=apikey`
  injects an Anthropic key from a Secret instead.
- **UI is a separate chart.** The UI ships as the `management` chart from
  `oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management`
  — NOT a toggle on the agentgateway chart. `02-install-ui.sh` also
  applies the `tracing` policy so traces flow into ClickHouse.
- **`ui-backend` CrashLoopBackOff with `Dirty database version …`.** `ui-backend`
  runs its ClickHouse migrations before it serves `/healthz`, and the chart's
  default liveness probe only allows ~40 s. On a cold cluster the migration run
  overruns that, the kubelet kills the container mid-migration, and golang-migrate
  is left dirty — a state that never self-heals, because every restart fast-fails
  on the dirty check before it can finish the migration that would clear the flag.
  `02-install-ui.sh` now passes `ui.backend.livenessProbe.initialDelaySeconds=300`
  and `failureThreshold=30` to prevent it.
  If you hit the wedged state on an older install, **relax the probe first** (a
  `kubectl patch` on the deployment) or the retry gets killed and re-dirtied, then
  drop the database and let it re-migrate from zero:
  `kubectl -n agentgateway-system exec management-clickhouse-shard0-0 -c clickhouse -- clickhouse-client -q "DROP DATABASE platformdb"`
  followed by `kubectl -n agentgateway-system rollout restart deploy/solo-enterprise-ui`.
  Prefer the drop over forcing the migration version: a partially applied migration
  can leave the `otel_traces_json` → `agw_spans_typed` → rollup chain half-built,
  which surfaces later as an empty Traces view rather than an error. Note the
  loudest symptom is a red herring — the healthy `k8sobjects-collector` sidecar
  logs `Database platformdb does not exist` because `ui-backend` is what creates it,
  so check `kubectl get pod -o json` to see which of the three containers is failing.
- **`Database platformdb does not exist` with NO dirty-migration error.** Same red
  herring, different cause.
  If `SHOW DATABASES` has no `platformdb` *at all*, `ui-backend` never reached its
  migrations — check its log for a `fatal` on OIDC discovery:
  `Get "https://keycloak.example.com/realms/solo/.well-known/openid-configuration":
  no such host`. That host is the **`.envrc.sample` placeholder**, so the install ran
  without your real `.envrc` loaded. The usual reason is direnv: **editing `.envrc`
  changes its hash and revokes the allow**, so the next shell silently loses the
  values. Run `direnv allow`, confirm with `echo $KEYCLOAK_ISSUER`, and re-run
  `./02-install-ui.sh` — no cleanup needed, since nothing was migrated there is no
  dirty state to recover. `common/keycloak-issuer.sh` now probes the issuer's
  discovery endpoint before any install touches the cluster, so this fails in a
  second with the real reason instead of four minutes later in the wrong container.
  Set `SOLO_SKIP_ISSUER_CHECK=1` to bypass it on an air-gapped rig.
- **Cost + Trace demo data.** `02-install-ui.sh` enables the agentgateway Cost
  Management dashboards (`products.agentgateway.features.cost-management=true`,
  off by default). To populate the Cost Management **and** Traces views with
  realistic figures **without any LLM API calls or spend**, run
  **`./seed-cost-data.sh`**: it seeds synthetic request **traces** at the source
  ClickHouse table the gateway writes to (`otel_traces_json`) — each request a
  small span tree (root request + LLM call + ~1/3 a tool call). The
  materialized-view chain then cascades them exactly like real traffic
  (`otel_traces_json` → `agw_spans_typed` → the cost rollups **and** trace
  rollups → chat spans), so one seed lights up the raw Traces explorer, the Cost
  Management dashboards (per-model / per-org / team / user / virtual-key / route
  / tool), and seeds a Virtual API Keys Secret. Idempotent
  (`NUM_REQUESTS`/`LOOKBACK_DAYS` tunable); `./seed-cost-data.sh --cleanup`
  removes it. Pairs with the `p02-routing-10` spend-budget demo.
- **Admin UIs on a public LB.** `08-install-admin-ingress.sh` exposes
  Keycloak, Grafana, and the Solo UI on a LoadBalancer over plain HTTP
  for demo simplicity. In any real environment, front them with TLS +
  a source-IP allow-list.
- **Logging into the Solo UI.** Keycloak's auth cookies are
  `Secure;SameSite=None`, so a browser only stores them in a secure context
  (HTTPS or `http://localhost`) — the SSO login won't complete over the
  plain-HTTP LB IP. Use **`./ui-login.sh`**: it port-forwards the UI to
  `localhost` and prints the URL (log in as `bob`, password in
  `DEMO_USER_BOB_PASSWORD`). Keycloak itself stays on its public HTTPS hostname,
  so its cookies are fine; only the UI needs the `localhost` secure context.
- **401 on every JWT demo? Restart `keycloak-jwks-proxy`.** Caddy parses its
  Caddyfile at startup, and that file lives in a ConfigMap nothing checksums into
  the pod template. So changing only the ConfigMap — e.g. re-running
  `01-install-agentgateway.sh` after correcting `KEYCLOAK_EXTERNAL_HOST` in
  `.envrc` — leaves the Deployment spec byte-identical: no new ReplicaSet, the pod
  is never recycled, and `rollout status` reports "successfully rolled out"
  instantly. The install looks clean while the old process keeps dialing the old
  upstream. Step 01 now
  forces the roll, so this only affects clusters installed before that change.
  The symptom is far from the cause: the gateway cannot fetch JWKS, and because
  `jwtAuthentication.mode: Strict` fails closed, **every** demo that applies
  `policy-jwt.yaml` returns 401 — `p02-routing-02`, `p02-routing-03`,
  `p03-agents-02`, `p05-security-01` through `05`. Confirm before blaming the
  token:
  ```bash
  kubectl -n agentgateway-system get enterpriseagentgatewaypolicy jwt-auth \
    -o jsonpath='{.status.ancestors[0].conditions}'
  ```
  `PartiallyValid: jwks keyset ... isn't available` means the bridge, not the JWT.
  Check what it is really dialing with
  `kubectl -n agentgateway-system logs deploy/keycloak-jwks-proxy | grep 'no such host'`,
  then `kubectl -n agentgateway-system rollout restart deploy/keycloak-jwks-proxy`.
- **WAF: a newline in the request body is a 403, whatever the rules say.**
  Attaching any `WAFPolicy` makes the gateway reject a request whose body
  contains a newline — including a single trailing one — with an empty-bodied
  403. Verified independent of `processingConfig.request.mode` and of whether
  `coreRuleSet` is set at all; the same request returns 200 with no `WAFPolicy`
  attached, so it is the WAF integration rather than a CRS signature, and no
  `SecRuleRemoveById` will clear it.
  Real OpenAI SDK clients send compact JSON so this does not bite live traffic,
  but a hand-written pretty-printed `curl` — or `jq -n` instead of `jq -cn` in a
  demo script — looks exactly like a WAF false positive and will make a benign
  prompt return 403.
- **WAF: a `WAFPolicy` alone does nothing.** It has no `targetRefs`. It stays
  dormant until an `EnterpriseAgentgatewayPolicy` names it under
  `spec.traffic.entWAF.wafPolicyRef`. Note the `traffic` level — kgateway's
  equivalent is `spec.entWAF` on an `EnterpriseKgatewayTrafficPolicy`, so a
  manifest copied across products is accepted but never attaches.
- **OBO needs step 09.** `demo/p05-security-03-obo.sh` expects `09-install-obo.sh`
  to have enabled `tokenExchange` on the control plane. If step 09 was
  skipped, the demo exits with a clear error.
- **OBO `JWKS not available for key` (HTTP 400 at the STS).** The STS's remote
  subject validator caches Keycloak's JWKS and does **not** re-fetch on an
  unknown key id, so after Keycloak rotates its signing key (or is rebuilt with
  `down -v`) the STS holds a stale JWKS and rejects an otherwise-valid subject
  token. Nothing is misconfigured — refresh the cache by restarting the
  controller, then re-run the demo (it also prints this hint on that error):
  `kubectl -n agentgateway-system rollout restart deploy/enterprise-agentgateway`.
- **MCP multiplexing can hang** if one upstream MCP server is down
 . Verify both MCP pods are `Ready` before
  running the agents demos.

## Layout

```
enterprise-agentgateway-demo/
├── README.md                          ← this file
├── keycloak/realm-agentgateway-demo.json   ← realm to import into YOUR Keycloak (no secrets)
├── common/                            ← shared shell helpers sourced by the scripts
├── architecture.md
├── .envrc.sample
├── .gitignore
├── 01-install-agentgateway.sh
├── 02-install-ui.sh
├── 03-install-observability.sh
├── 05-install-eso.sh
├── 06-install-llm-backends.sh
├── 07-install-mcp-agents.sh
├── ui-login.sh                   (localhost port-forward UI/Keycloak login helper)
├── seed-cost-data.sh             (seed synthetic traces → Cost Management + Traces UI, no LLM spend; --cleanup)
├── 08-install-admin-ingress.sh
├── 09-install-obo.sh
├── 10-install-elicitation.sh
├── install-all.sh
├── cleanup-all.sh
├── demo/
│   ├── _common.sh
│   ├── p02-routing-*.sh               (10)
│   ├── p03-agents-*.sh                 (7)
│   ├── p05-security-*.sh               (6)
│   ├── p07-observability-*.sh          (1)
│   ├── p08-modelcontrols-*.sh          (1)
│   ├── p09-selfhosted-*.sh             (3)
│   └── deprecated/                        (excluded from the demo set)
└── manifests/
    ├── gateway.yaml
    ├── admin-gateway.yaml
    ├── httproute-*.yaml
    ├── agentgatewaybackend-*.yaml
    ├── policy-*.yaml
    ├── ratelimitconfig.yaml
    ├── mock-llm-deployment.yaml
    ├── mcp-*.yaml
    ├── a2a-agent.yaml
    ├── eso-*.yaml
    ├── agent-service-account.yaml
    ├── apikeys-vllm.yaml
    ├── vllm-mock-deployment.yaml
    └── referencegrant-a2a.yaml
```

Keycloak is not deployed by this demo — see [`keycloak/`](keycloak/) for the
realm to import into your own server.
