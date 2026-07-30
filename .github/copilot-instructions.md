# Copilot instructions — locked-down Foundry M365 agent

A network-secured Azure AI Foundry agent environment (private VNet, private
endpoints, CMK encryption, RBAC). **`azd` is the only supported deployment path.**

## Repository layout

| Path | Purpose |
|---|---|
| `infra/main.bicep` | Thin deployment orchestrator — declares params + addressing vars and calls the sequential stages under `infra/stages/`. |
| `infra/main.parameters.json` | **azd** parameter source. Maps each Bicep param to an env var with an inline default (`${VAR=default}`). |
| `infra/stages/<NN>-<name>/` | Sequential deployment stages (`00-foundation`, `10-platform`, `20-workload-mcp`, `30-governance`, `40-runner`). Each stage's Bicep modules are **localised inside it** under category subfolders (`network/`, `foundry/`, `rbac/`, `resources/`, `encryption/`, `gateway/`, `governance/`, `model-gateway/`). No shared `infra/modules/` tree — a module lives under the one stage that consumes it. |
| `azure.yaml` | Wires `infra/`, two `services:` (the MCP Node app `mcp/agent-tools` + the YARP .NET app `apps/sample-gateway`, both `host: appservice` deployed as CODE), and the `preprovision`, `postprovision`, `predeploy`, `postdeploy` and `predown` hooks. azd provisions, syncs repo variables (`postprovision`), then deploys the two apps' code (wrapped by `predeploy`/`postdeploy`). Still no agent deploys — those stay workflow-only. |
| `hooks/postprovision.ps1` | azd **postprovision** hook — host-side only; pushes the Bicep outputs the workflows consume into GitHub Actions repo variables via `gh variable set` (rename: `MCP_SERVER_URL` ← `MCP_GATEWAY_URL`). Best-effort (`continueOnError: true`); never touches the VNet. |
| `hooks/predeploy.ps1` / `hooks/postdeploy.ps1` | azd **predeploy**/**postdeploy** hooks — host-side; open (then re-lock) the deny-by-default SCM sites of the MCP + YARP web apps for the deployer's public IP (MCP also toggles `publicNetworkAccess`) so azd can zip-deploy the app code. Both dot-source `hooks/appservice-scm-common.ps1`. |
| `hooks/predown.ps1` | azd **predown** hook — deregisters the GitHub runner **host-side via `gh`** (delete by name `<vmName>-vnet`) + deletes capability hosts before teardown. |
| `scripts/create-agent.ps1` / `scripts/publish-agent.ps1` | Run **on the private Linux VM** (natively via the reusable `deploy-agent.yml` workflow) to create-or-update and publish one agent. Both dot-source `scripts/foundry-agent-common.ps1`. |
| `agents/<name>/agent.yaml` | Per-agent manifest (`kind: prompt` — model + instructions, optionally an MCP tool). One folder per agent; model is set in the manifest, MCP `server_url` (if any) is injected at deploy time. |

`hooks/` and `scripts/` intentionally live at the repo root (deploy orchestration, not IaC).
For a per-file map of what triggers each one, where it runs (azd host vs in-VNet VM) and which
identity it uses, see `docs/what-runs-where.md`.
Most don't reference Bicep file paths; the exception is the in-VNet agent-network workflow
(`.github/workflows/deploy-agent-network.yml`), whose MCP-allowlist step deploys
`infra/stages/30-governance/model-gateway/apim-mcp-compliance-all.bicep` by path — keep
that path in sync if the module moves.

## Deployment lifecycle

```
azd up
 └─ provision  → deploys infra/main.bicep (all Azure resources). Nothing runs after provision.

Post-provision (agent seeding, network governance)
 └─ in-VNet self-hosted runner workflows — run natively on the private VM:
    * one thin per-agent workflow each (deploy-teams-agent.yml) → the reusable deploy-agent.yml
    * deploy-agent-network.yml (Foundry token limits + YARP edge routes + MCP allowlist)

azd down
 └─ (predown hook) → deregisters the runner + deletes capability hosts, then teardown.
```

### 1. Provision (`azd provision`, or the provision phase of `azd up`)
- Deploys `infra/main.bicep` using params resolved from `infra/main.parameters.json`.
- azd reads defaults from `${VAR=default}` entries and substitutes any overrides set via
  `azd env set VAR value`. It coerces string values to `int`/`bool` where the param type
  requires it (use lowercase `true`/`false`).
- `vmAdminPassword` has **no** default and is **omitted** from `main.parameters.json`, so azd
  **prompts for it interactively** — it is never stored in the repo.
- **azd deploys no agents** — post-provision it runs the `postprovision` hook (syncs repo
  variables via `gh variable set` so the workflows just work) and then its deploy phase pushes the
  two App Service **code** `services:` (MCP + YARP). Agent seeding/compliance/publish are
  workflow-only (below).
- **Known transient failure:** provisioning can fail the first time with
  `KeyVaultAuthenticationFailure` / `AccessPolicyNotConfiguredForKeyVault`. This is an RBAC
  **role-assignment propagation delay** (the Key Vault Crypto role granted to the AI Services /
  Storage identities takes 1–5 min to become effective in the KV data plane, and the CMK
  enablement step can run before it does). The deployment is **idempotent** — just re-run
  `azd provision`. It is not a soft-delete or name-collision problem.

### 2. Post-provision — in-VNet runner workflows (no azd involvement)
- The Foundry endpoint is **private**, so agent deploys / Teams publishing / MCP compliance run
  on the **in-VNet self-hosted GitHub Actions runner** (which IS the private Linux VM), reaching
  the endpoint directly. The runner is therefore **required** for these steps.
- **One agent per workflow.** Each agent has a manifest (`agents/<name>/agent.yaml`) and a thin
  caller workflow (`deploy-<name>-agent.yml`) that `uses:` the reusable
  `.github/workflows/deploy-agent.yml`. The reusable workflow converts the manifest with `yq`,
  injects the MCP `server_url` if present, then runs the `create-agent` and
  `publish-agent` composite actions; an optional `publish-teams` job publishes that single
  agent. `deploy-agent-network.yml` applies the network governance (Foundry token limits + YARP
  edge routes + MCP allowlist). All are `workflow_dispatch`-only, repository-guarded.
- Idempotent: an existing agent (matched by name) gets a fresh version. Add an agent by adding a
  manifest folder + a thin caller workflow.
- The runner VM's managed identity holds **Foundry User** on the project (so `create-agent.ps1` /
  `publish-agent.ps1` call the Agents API via IMDS) and **Contributor** on the RG (so the Teams
  path can deploy the Bot Service). VM name is surfaced as the `GITHUB_ACTIONS_RUNNER_VM_NAME`
  Bicep output.

### 3. Predown hook — runner deregistration + capability-host cleanup (`hooks/predown.ps1`)
- Runs on the azd host **before** `azd down` deletes anything. Two best-effort phases.
- **Phase 0 (runner):** if a self-hosted runner was installed, deregisters it BEFORE the VM is
  deleted (else it lingers as "offline"). Runs **host-side** with the GitHub CLI (`gh`) using the
  caller's own credentials — no PAT, no Key Vault, no VM round-trip. The runner name is
  deterministic (`<vmName>-vnet`: the bootstrap names it `<hostname>-vnet` and the VM's
  `computerName` IS the VM name), so it deletes by name via `gh api .../actions/runners`. Needs
  `GITHUB_RUNNER_REPO_URL`, `GITHUB_ACTIONS_RUNNER_VM_NAME`, and a host `gh` login with repo
  admin. Never fails teardown. (No on-VM script — the old `deregister-runner.ps1` +
  `vm-run-command.ps1` shim were removed; there is now no host→VM path at all.)
- **Phase 1/2 (capability hosts):** a Foundry account/project with an **Agents capability host**
  cannot be deleted cleanly while the capability host exists, so the hook deletes it first, in
  strict order: **project-scope capability hosts, THEN account-scope** (`az resource delete`
  polls the long-running delete to completion). Control-plane ARM — does NOT need the VM.
- Requires `AZURE_RESOURCE_GROUP`, `AZURE_AI_ACCOUNT_NAME`, `AZURE_AI_PROJECT_NAME` (Bicep
  outputs) plus `AZURE_SUBSCRIPTION_ID` (an azd built-in env var; falls back to
  `az account show`). Run `azd env refresh` if the Bicep outputs are missing.
- Best-effort by design: if Foundry was never provisioned it no-ops; if a real enumeration or
  delete error occurs it throws (with `continueOnError: false` this fails `azd down` early,
  which is correct — the teardown would fail anyway).
- Caller RBAC: delete capability hosts (e.g. Cognitive Services Contributor) + invoke VM
  run-commands (e.g. Virtual Machine Contributor) for Phase 0.

## Conventions & gotchas

- **Build the template:** `az bicep build --file infra/main.bicep`. Check the `az` exit code,
  not a `grep` of the output (piping a clean build to `grep -c "Error "` exits non-zero).
  ~23 pre-existing warnings (BCP318/036/037) are expected; **0 errors** is the bar.
- **azd ignores `.bicepparam`.** It reads `<module>.parameters.json` next to the module. Change
  provisioning defaults in `infra/main.parameters.json`, not in a `.bicepparam`.
- **`.gitignore` ignores `*.json`** (compiled ARM templates). `infra/main.parameters.json` is
  kept trackable via a `!infra/main.parameters.json` negation — preserve it. Verify with
  `git check-ignore <file>`.
- **pwsh hooks calling `az ... 2>&1`:** merging stderr mixes CLI warning `ErrorRecord`s into the
  captured output; piping that array to `ConvertFrom-Json` throws on success-with-warning.
  Filter `Where-Object { $_ -is [string] }` before parsing (see `hooks/predown.ps1`).
- **Foundry Agents API** returns agents under `.data` (OpenAI schema), **not** `.value`.
- **Adding a new env var for a workflow/hook:** add a matching `output NAME ...` in
  `infra/main.bicep` (azd surfaces outputs as env vars verbatim; they are already UPPER_SNAKE).
  If a workflow reads it as `vars.NAME`, also add it to the `$variableMap` in
  `hooks/postprovision.ps1` so the postprovision sync pushes it to repo variables. Hooks (predown)
  read outputs straight from the env.
- **`azure.yaml` has two `services:` (MCP Node app + YARP .NET app) deployed as code, plus
  `predeploy`/`postdeploy` hooks** that open and re-lock the apps' SCM sites for the deploy. azd
  provisions, runs the host-side `postprovision` step (repo-variable sync), then deploys the two
  apps' code. `predown` runs on any `azd down`. All agent/compliance/publish work is still the
  in-VNet runner workflows.

## AI gateway (a.k.a. model gateway in Bicep)
The shared private APIM instance is always deployed. Bicep still names it `model-gateway`
(modules, the `model-gateway` connection, the `10.3.0.0/16` spoke), but the docs frame it as the
broader **AI gateway**: it fronts models (APIM-fronted provider Foundry + a second seeded agent
routed through it), MCP servers, and the Teams/M365 inbound auth checks. See `docs/ai-gateway.md`
(full design + MCP governance) and `docs/governance.md` (governance overview). Networking
deep-dive: `docs/NETWORKING.md`.

## MCP compliance (agent → APIM allowlist)
`mcp/mcp-policy.json` is the **name-only** source of truth (deny-by-default). At apply time,
`scripts/list-agent-appids.ps1` (RESOLVE mode) maps each agent name to its live AppId read from the
Foundry **data plane** (`instance_identity.client_id` on the project endpoint — the authoritative
runtime identity; names with no matching / identity-less agent are dropped), then
`infra/stages/30-governance/model-gateway/apim-mcp-compliance-all.bicep` writes the APIM policy. At
provision, `main.bicep` applies a deny-all policy; the real (resolved) policy is then applied
**only** by the MCP-allowlist step of `.github/workflows/deploy-agent-network.yml` (run it after
agents are seeded, and again whenever you edit the JSON). Because resolution reads the private data
plane, that workflow **must** run on the in-VNet self-hosted runner (VM managed identity via IMDS) —
no Microsoft Graph permission is needed. azd deploys no agents post-provision, so a fresh `azd up`
leaves MCP deny-all
until that workflow runs.
