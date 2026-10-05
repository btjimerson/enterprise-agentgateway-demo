<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
# Contents

- [Vendored Grafana dashboards](#vendored-grafana-dashboards)
  - [`agentgateway-dashboard.json`](#agentgateway-dashboardjson)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

# Vendored Grafana dashboards

## `agentgateway-dashboard.json`

The official Agentgateway control-plane + data-plane dashboard. Title
`Agentgateway`, rows **Overview · Requests · LLM · MCP** — the ones
`demo/p07-observability-01-grafana.sh` points you at.

**Why it is vendored.** `03-install-observability.sh` used to fetch this by URL
from the upstream docs site:

```
https://raw.githubusercontent.com/agentgateway/website/main/content/docs/kubernetes/main/observability/agentgateway.json
```

Upstream **deleted** it from `main` and `latest` — it now only exists under the
versioned doc directories. That URL returned `404` while the install carried on
regardless, so the `Agentgateway` folder in Grafana came up empty and the p07
demo pointed at a dashboard that did not exist.

Vendoring means a docs-site reshuffle can't silently break the demo again.

**Provenance.** Copied from `agentgateway/website` at
`content/docs/kubernetes/2.2.x/observability/agentgateway.json` — the newest
version directory that still carries the file. Reformatted with 2-space indent;
content otherwise unmodified. `schemaVersion: 36`, `uid: agentgateway`.

**To refresh**, check whether a newer version directory has reintroduced it:

```bash
gh api repos/agentgateway/website/contents/content/docs/kubernetes --jq '.[].name'
gh api repos/agentgateway/website/contents/content/docs/kubernetes/<ver>/observability --jq '.[].name'
```

then re-download and re-run `./03-install-observability.sh`.

**Datasource.** The dashboard declares a `datasource` template variable of type
`datasource` (query `prometheus`) with no `${DS_*}` placeholders and no
`__inputs` block, so it loads as a plain ConfigMap dashboard with no
substitution. The Grafana install marks its Prometheus datasource
`isDefault=true`, so the picker resolves on its own.

Both this dashboard and the inline "Agentgateway — Tokens, Cost, Latency" one are
provisioned through the Grafana sidecar into the **`Agentgateway`** folder
(`sidecar.dashboards.provider.folder`), so they appear together.
