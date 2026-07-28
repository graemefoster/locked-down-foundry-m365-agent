# What runs where — `hooks/` and `scripts/` orientation

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
`predown` reaches into the VNet (indirectly, via the shim below).

| File | Trigger (azd) | Runs on | Identity | What it does |
|---|---|---|---|---|
| `preprovision.ps1` | before `azd provision` | azd host | none (writes azd env) | Interactive first-run prompts (`DEPLOY_WINDOWS_VM`, `GITHUB_RUNNER_REPO_URL`); idempotent, no-ops in CI. |
| `postprovision.ps1` | after `azd provision` | azd host | `gh` auth | Pushes the Bicep outputs the workflows consume into GitHub Actions **repo variables** via `gh variable set` (so the deploy workflows just work). Best-effort. |
| `predown.ps1` | before `azd down` | azd host | `az` (yours) | **Phase 0:** deregister the self-hosted runner (runs `deregister-runner.ps1` **on the VM** via the shim). **Phase 1/2:** delete Foundry capability hosts (ARM control plane) so the account/project can be torn down. |
| `vm-run-command.ps1` | *(not a hook — a shared shim)* | azd host → VM | `az vm run-command` | Dot-sourced by `predown.ps1`. Ships a `.ps1` to the **Linux** VM via `RunShellScript` (quoted heredoc, no shell expansion) and runs it under `pwsh` with named params. The **only** remaining host→VM orchestration path. |

`bot-service.bicep` also lives in `hooks/` (deployed by the Teams-publish path); it is IaC, not a
hook script.

---

## `scripts/` — run on the **in-VNet VM** (self-hosted runner), invoked by GitHub workflows

Everything under `scripts/` runs on the VM because it needs the private Foundry endpoint (or, for
teardown, the Key-Vault-protected PAT). They authenticate as the **VM managed identity via IMDS**
— never `az login`.

### Agent create / publish (reusable `deploy-agent.yml`)

| File | Invoked by | Runs on | Identity | What it does |
|---|---|---|---|---|
| `create-agent.ps1` | `create-agent` composite action | VM runner | VM MI (IMDS) | Create-or-update one agent from the normalized `agent.json`. Does **not** change which version serves traffic. |
| `publish-agent.ps1` | `publish-agent` composite action | VM runner | VM MI (IMDS) | Route 100% of the agent endpoint's traffic to a version ("Publish Updates"). |
| `foundry-agent-common.ps1` | *(dot-sourced by the two above)* | VM runner | VM MI (IMDS) | **Single source of truth** for the Foundry Agents REST helpers (token via IMDS, GET/POST/PATCH). No external modules. |

Chain: `deploy-<name>-agent.yml` → `deploy-agent.yml` → `yq` (manifest→json) → `create-agent`
action → `create-agent.ps1` → `publish-agent` action → `publish-agent.ps1`.

### Teams / M365 publish (optional `publish-teams` job in `deploy-agent.yml`)

| File | Invoked by | Runs on | Identity | What it does |
|---|---|---|---|---|
| `publish-teams-runner.ps1` | `publish-teams` composite action | VM runner | VM MI + delegated **user** token | VNet **orchestrator**: reads the agent identity, creates its Azure Bot Service (VM MI is Contributor on the RG), then drives the publish. |
| `publish-teams.ps1` | *(invoked by `publish-teams-runner.ps1`)* | VM | VM MI + delegated user token | **Core logic** (single source of truth): `-Mode GetIdentity` (read agent identity) and `-Mode Publish` (PATCH activity protocol + POST the M365 publish API). |

The M365 publish call rejects app-only / MI tokens (HTTP 502), so the composite action acquires a
delegated **user** token (device-code sign-in) and forwards it for that step only.

### MCP compliance (`deploy-compliancy.yml`)

| File | Invoked by | Runs on | Identity | What it does |
|---|---|---|---|---|
| `list-agent-appids.ps1` | `deploy-compliancy.yml` (RESOLVE mode) | VM runner | VM MI (IMDS) — **data plane** | Joins each agent **name** in `mcp/mcp-policy.json` to its live `instance_identity.client_id` read from the Foundry data plane and emits the resolved policy for the APIM allowlist Bicep. DISCOVERY mode (default) prints every agent's AppId + a paste-ready policy array. Both modes need the private endpoint → the VM. |

### Teardown

| File | Invoked by | Runs on | Identity | What it does |
|---|---|---|---|---|
| `deregister-runner.ps1` | `predown.ps1` (via `vm-run-command.ps1`) | VM | VM MI (IMDS) → Key Vault | Reads the runner PAT from Key Vault (private endpoint), mints a REMOVE token, and deregisters the self-hosted runner before the VM is deleted. Best-effort. |

---

## One-glance rules of thumb

- **Private Foundry data plane?** → runs on the **VM** as the VM managed identity (IMDS).
- **ARM / Graph / `gh` control plane only?** → can run on the **azd host** as your CLI login.
- **azd host → VM** only ever happens through `hooks/vm-run-command.ps1` (used solely by
  `predown`). azd does **no** agent deploys — that is 100% the in-VNet runner workflows.
- **`foundry-agent-common.ps1`** (agents) and **`publish-teams.ps1`** (Teams) are the two "single
  source of truth" scripts; the runner-side scripts orchestrate, they don't reimplement.
