# What runs where — `hooks/` and `scripts/` orientation

> **Cross-cutting** (supports Levels 2 & 3). Part of the
> [locked-down Foundry agent](../README.md) reference implementation.

A newcomer's map of every PowerShell file in this repo: **what triggers it, where it runs, what
identity it uses, and what it does.** The golden rule of this locked-down design:

> The Foundry endpoint is **private**. Anything that must call the Foundry data plane (agents,
> publish, identity discovery) has to run **on the in-VNet Linux worker VM**. Anything that only
> talks to the Azure/GitHub **control plane** (ARM, Graph, `gh`) can run on the **azd host**
> (your laptop / CI).

There are two hosts, and they authenticate differently:

| Host | What it is | How it authenticates |
|---|---|---|
| **azd host** | your laptop / CI running `azd` | your interactive `az login` + `gh auth login` |
| **in-VNet VM** | the locked-down Linux worker VM, also the self-hosted GitHub Actions runner | the VM's **managed identity** via IMDS (`169.254.169.254`) — no `az login` |

---

## `hooks/` — run on the **azd host**, wired by `azure.yaml`

These are azd lifecycle hooks. They run where you run `azd`, using your CLI credentials. Only
`predown` reaches into the VNet (indirectly). `predeploy`/`postdeploy` only toggle the App
Services' public SCM access-restrictions (control plane) so a host-side zip-deploy can land.

| File | Trigger (azd) | Runs on | Identity | What it does |
|---|---|---|---|---|
| `preprovision.ps1` | before `azd provision` | azd host | none (writes azd env) | Interactive first-run prompts (`DEPLOY_WINDOWS_VM`, `GITHUB_RUNNER_REPO_URL`); idempotent, no-ops in CI. |
| `postprovision.ps1` | after `azd provision` | azd host | `gh` auth | Pushes the Bicep outputs the workflows consume into GitHub Actions **repo variables** via `gh variable set` (so the deploy workflows just work). Best-effort. |
| `predeploy.ps1` | before `azd deploy` | azd host | `az` (yours) | **Opens** the deny-by-default SCM (Kudu) sites of the MCP + YARP web apps for your public IP so azd can zip-deploy their code (MCP also flips `publicNetworkAccess` to Enabled). Dot-sources `appservice-scm-common.ps1`. |
| `postdeploy.ps1` | after `azd deploy` | azd host | `az` (yours) | **Re-locks** those SCM sites (removes the temporary allow rule; re-disables public access on the private MCP app). Best-effort — re-run `azd hooks run postdeploy` if a deploy failure left it open. |
| `predown.ps1` | before `azd down` | azd host | `az` (yours) + `gh` | **Phase 0:** deregister the self-hosted runner **host-side** via `gh api` (delete by name `<vmName>-vnet`) — no PAT, no VM round-trip. **Phase 1/2:** delete Foundry capability hosts (ARM control plane) so the account/project can be torn down. |
| `appservice-scm-common.ps1` | *(dot-sourced by predeploy/postdeploy)* | azd host | `az` (yours) | Shared helpers to resolve the deployer IP and open/close a web app's SCM access restriction + `publicNetworkAccess`. |

`bot-service.bicep` also lives in `hooks/` (deployed by the Teams-publish path); it is IaC, not a
hook script.

---

## `scripts/` — run on the **in-VNet VM** (self-hosted runner), invoked by GitHub workflows

Everything under `scripts/` runs on the VM because it needs the private Foundry endpoint. They
authenticate as the **VM managed identity via IMDS** — never `az login`.

### Agent create / publish (reusable `_deploy-agent.yml`)

| File | Invoked by | Runs on | Identity | What it does |
|---|---|---|---|---|
| `create-agent.ps1` | `create-agent` composite action | VM runner | VM MI (IMDS) | Create-or-update one agent from the normalized `agent.json`. Does **not** change which version serves traffic. |
| `publish-agent.ps1` | `publish-agent` composite action | VM runner | VM MI (IMDS) | Route 100% of the agent endpoint's traffic to a version ("Publish Updates"). |
| `foundry-agent-common.ps1` | *(dot-sourced by the two above)* | VM runner | VM MI (IMDS) | **Single source of truth** for the Foundry Agents REST helpers (token via IMDS, GET/POST/PATCH). No external modules. |

Chain: `deploy-<name>-agent.yml` → `_deploy-agent.yml` → `yq` (manifest→json) → `create-agent`
action → `create-agent.ps1` → `publish-agent` action → `publish-agent.ps1`.

### Teams / M365 publish (optional `publish-teams` job in `_deploy-agent.yml`)

| File | Invoked by | Runs on | Identity | What it does |
|---|---|---|---|---|
| `publish-teams-runner.ps1` | `publish-teams` composite action | VM runner | VM MI + delegated **user** token | VNet **orchestrator**: reads the agent identity, creates its Azure Bot Service (VM MI is Contributor on the RG), then drives the publish. |
| `publish-teams.ps1` | *(invoked by `publish-teams-runner.ps1`)* | VM | VM MI + delegated user token | **Core logic** (single source of truth): `-Mode GetIdentity` (read agent identity) and `-Mode Publish` (PATCH activity protocol + POST the M365 publish API). |

The M365 publish call rejects app-only / MI tokens (HTTP 502), so the composite action acquires a
delegated **user** token (device-code sign-in) and forwards it for that step only.

### MCP allowlist (part of `deploy-agent-network.yml`)

| File | Invoked by | Runs on | Identity | What it does |
|---|---|---|---|---|
| `list-agent-appids.ps1` | `deploy-agent-network.yml` (RESOLVE mode) | VM runner | VM MI (IMDS) — **data plane** | Joins each agent **name** in `mcp/mcp-policy.json` to its live `instance_identity.client_id` read from the Foundry data plane and emits the resolved policy for the APIM allowlist Bicep. DISCOVERY mode (default) prints every agent's AppId + a paste-ready policy array. RESOLVE-TEAMS-AUDIENCE mode (`-ResolveTeamsAudience true`) maps the `exposeToM365` agent names to their bot App IDs (`instance_identity.principal_id`) and emits the `botAppIds` array the same workflow feeds to `apim-teams-api.bicep` to pin the Teams validate-jwt audience. All modes need the private endpoint → the VM. |

### Teardown

Runner deregistration at `azd down` now runs **host-side** in `hooks/predown.ps1` (Phase 0) via
`gh api` — see the hooks table above. Nothing under `scripts/` is involved in teardown anymore.

---

## One-glance rules of thumb

- **Private Foundry data plane?** → runs on the **VM** as the VM managed identity (IMDS).
- **ARM / Graph / `gh` control plane only?** → can run on the **azd host** as your CLI login
  (e.g. `postprovision` repo-variable sync and `predown` Phase 0 runner deregistration).
- **azd no longer orchestrates the VM at all** — there is no host→VM path; agent deploys are
  100% the in-VNet runner workflows, and teardown deregistration is host-side `gh`.
- **`foundry-agent-common.ps1`** (agents) and **`publish-teams.ps1`** (Teams) are the two "single
  source of truth" scripts; the runner-side scripts orchestrate, they don't reimplement.
