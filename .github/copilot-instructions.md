# Copilot instructions — locked-down Foundry M365 agent

A network-secured Azure AI Foundry agent environment (private VNet, private
endpoints, CMK encryption, RBAC). **`azd` is the only supported deployment path.**

## Repository layout

| Path | Purpose |
|---|---|
| `infra/main.bicep` | Thin deployment orchestrator — declares params + addressing vars and calls the sequential stages under `infra/stages/`. |
| `infra/main.parameters.json` | **azd** parameter source. Maps each Bicep param to an env var with an inline default (`${VAR=default}`). |
| `infra/stages/<NN>-<name>/` | Sequential deployment stages (`00-foundation`, `10-platform`, `20-workload-mcp`, `30-governance`, `40-runner`). Each stage's Bicep modules are **localised inside it** under category subfolders (`network/`, `foundry/`, `rbac/`, `resources/`, `encryption/`, `gateway/`, `governance/`, `model-gateway/`). No shared `infra/modules/` tree — a module lives under the one stage that consumes it. |
| `azure.yaml` | Wires `infra/` + the `preprovision` and `predown` hooks. **azd runs nothing after provision** — no predeploy/postdeploy. |
| `hooks/predown.ps1` | azd **predown** hook — deregisters the in-VNet GitHub runner (on the VM) + deletes capability hosts before teardown. |
| `hooks/vm-run-command.ps1` | Shared shim — copies a `.ps1` to the **Linux** VM via `RunShellScript` and runs it under `pwsh` with named params. Now used only by `predown` (runner deregistration). |
| `scripts/create-agent.ps1` / `scripts/publish-agent.ps1` | Run **on the private Linux VM** (natively via the reusable `deploy-agent.yml` workflow) to create-or-update and publish one agent. Both dot-source `scripts/foundry-agent-common.ps1`. |
| `agents/<name>/agent.yaml` | Per-agent manifest (`kind: prompt` — model + instructions, optionally an MCP tool). One folder per agent; env-specific model / MCP URL are injected at deploy time. |

`hooks/` and `scripts/` intentionally live at the repo root (deploy orchestration, not IaC).
Most don't reference Bicep file paths; the exception is the in-VNet MCP-compliance workflow
(`.github/workflows/deploy-compliancy.yml`), which deploys
`infra/stages/30-governance/model-gateway/apim-mcp-compliance-all.bicep` by path — keep
that path in sync if the module moves.

## Deployment lifecycle

```
azd up
 └─ provision  → deploys infra/main.bicep (all Azure resources). Nothing runs after provision.

Post-provision (agent seeding, MCP compliance, Teams publish)
 └─ in-VNet self-hosted runner workflows — run natively on the private VM:
    * one thin per-agent workflow each (deploy-hello-world-agent.yml, deploy-gateway-model-agent.yml,
      deploy-teams-agent.yml, deploy-test-agent-one.yml) → the reusable deploy-agent.yml
    * deploy-compliancy.yml (MCP compliance)

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
- **azd runs NOTHING after provision** — seeding/compliance/publish are workflow-only (below).
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
  injects the per-env model (and MCP `server_url` if present), then runs the `create-agent` and
  `publish-agent` composite actions; an optional gated `publish-teams` job publishes that single
  agent. `deploy-compliancy.yml` applies MCP compliance. All are `workflow_dispatch`-only,
  repository-guarded; the Teams-publish / compliance steps are gated by the `vnet-deploy`
  environment.
- Idempotent: an existing agent (matched by name) gets a fresh version. Add an agent by adding a
  manifest folder + a thin caller workflow.
- The runner VM's managed identity holds **Foundry User** on the project (so `create-agent.ps1` /
  `publish-agent.ps1` call the Agents API via IMDS) and **Contributor** on the RG (so the Teams
  path can deploy the Bot Service). VM name is surfaced as the `GITHUB_ACTIONS_RUNNER_VM_NAME`
  Bicep output.

### 3. Predown hook — runner deregistration + capability-host cleanup (`hooks/predown.ps1`)
- Runs on the azd host **before** `azd down` deletes anything. Two best-effort phases.
- **Phase 0 (runner):** if a self-hosted runner was installed, deregisters it BEFORE the VM is
  deleted (else it lingers as "offline"). The PAT lives in Key Vault behind a private endpoint,
  so the actual work runs **on the VM** via `Invoke-VmPwshScript` (`hooks/vm-run-command.ps1` →
  `scripts/deregister-runner.ps1`) — the only remaining use of the vm-run-command shim. Needs
  `GITHUB_ACTIONS_RUNNER_VM_NAME`, `GITHUB_RUNNER_REPO_URL`, `KEY_VAULT_NAME`,
  `GITHUB_RUNNER_PAT_SECRET_NAME`. Never fails teardown.
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
  `infra/main.bicep` (azd surfaces outputs as env vars verbatim; they are already UPPER_SNAKE),
  then read it in the workflow (as a repo variable) or the predown hook.
- **`azure.yaml` has no `services:` and no predeploy/postdeploy hooks** — azd only provisions.
  `predown` runs on any `azd down`. All post-provision work is the in-VNet runner workflows.

## Model gateway
The model gateway is always deployed: an APIM-fronted provider Foundry and a
second seeded agent routed through it. See `apim-model-gateway.md`. Networking deep-dive:
`NETWORKING.md`.

## MCP compliance (agent → APIM allowlist)
`mcp/mcp-policy.json` is the **name-only** source of truth (deny-by-default). At apply time,
`scripts/list-agent-appids.ps1` (RESOLVE mode) maps each agent name to its Entra
`ServiceIdentity` SP AppId via the **control plane** (`az ad sp list` on display name
`<account>-<project>-<agent>-AgentIdentity`, newest `createdDateTime` wins on duplicates), then
`infra/stages/30-governance/model-gateway/apim-mcp-compliance-all.bicep` writes the APIM policy. At
provision, `main.bicep` applies a deny-all policy; the real (resolved) policy is then applied
**only** by `.github/workflows/deploy-compliancy.yml` (run it after agents are seeded, and again
whenever you edit the JSON). azd runs nothing after provision, so a fresh `azd up` leaves MCP
deny-all until that workflow runs.

> **⚠️ NOTE (per @graemefoster, 2026-07-27): the azd/postdeploy compliance flow has now been
> removed** (azd provisions only). MCP compliance is workflow-only and still resolves AppIds via
> the **control plane** (`az ad sp list`). If you want the authoritative DATA-plane resolution
> instead (the in-VNet VM reading `instance_identity.client_id`, i.e. DISCOVERY mode in
> `scripts/list-agent-appids.ps1`), switch `deploy-compliancy.yml` to it — the data plane avoids
> the control-plane display-name trust model (see the SECURITY header block in that script).
