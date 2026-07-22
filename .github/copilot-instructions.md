# Copilot instructions — locked-down Foundry M365 agent

A network-secured Azure AI Foundry agent environment (private VNet, private
endpoints, CMK encryption, RBAC). **`azd` is the only supported deployment path.**

## Repository layout

| Path | Purpose |
|---|---|
| `infra/main.bicep` | Deployment orchestrator. All resources are declared/wired here. |
| `infra/main.parameters.json` | **azd** parameter source. Maps each Bicep param to an env var with an inline default (`${VAR=default}`). |
| `infra/modules/{network,foundry,resources,encryption,rbac,model-gateway}/` | Categorized Bicep modules. |
| `azure.yaml` | Wires `infra/` + the `predeploy` and `predown` hooks. |
| `hooks/predeploy.ps1` | azd **predeploy** hook — seeds Foundry agents. |
| `hooks/predown.ps1` | azd **predown** hook — deletes capability hosts before teardown. |
| `scripts/seed-agents.ps1` | Runs **on the private VM** (via `az vm run-command`) to create agents. |

`hooks/` and `scripts/` intentionally live at the repo root (deploy orchestration,
not IaC) and do **not** reference Bicep file paths, so moving modules never breaks them.

## Deployment lifecycle

```
azd up
 ├─ provision  → deploys infra/main.bicep (all Azure resources)
 └─ deploy     → (predeploy hook) → deploys services (none defined yet)

azd down
 └─ (predown hook) → deletes the resource group
```

### 1. Provision (`azd provision`, or the provision phase of `azd up`)
- Deploys `infra/main.bicep` using params resolved from `infra/main.parameters.json`.
- azd reads defaults from `${VAR=default}` entries and substitutes any overrides set via
  `azd env set VAR value`. It coerces string values to `int`/`bool` where the param type
  requires it (use lowercase `true`/`false`).
- `vmAdminPassword` has **no** default and is **omitted** from `main.parameters.json`, so azd
  **prompts for it interactively** — it is never stored in the repo.
- **Does NOT seed agents** — seeding is a separate deploy-time step (below).
- **Known transient failure:** provisioning can fail the first time with
  `KeyVaultAuthenticationFailure` / `AccessPolicyNotConfiguredForKeyVault`. This is an RBAC
  **role-assignment propagation delay** (the Key Vault Crypto role granted to the AI Services /
  Storage identities takes 1–5 min to become effective in the KV data plane, and the CMK
  enablement step can run before it does). The deployment is **idempotent** — just re-run
  `azd provision`. It is not a soft-delete or name-collision problem.

### 2. Predeploy hook — seed agents (`hooks/predeploy.ps1`)
- Runs on the azd host (laptop / CI), triggered by `azd deploy` (once a service is defined) or
  directly via `azd hooks run predeploy`.
- The Foundry endpoint is **private**, so the host cannot call the Agents API directly. The
  hook instead uses `az vm run-command` to execute `scripts/seed-agents.ps1` **on the
  locked-down VM inside the VNet**, which can reach the private endpoint.
- Idempotent: existing agents (matched by name) are skipped. Edit the `$agentsToCreate` array
  in `scripts/seed-agents.ps1` to change which agents are seeded.
- Requires these Bicep **outputs** (surfaced by azd as env vars): `AZURE_RESOURCE_GROUP`,
  `SEED_AGENTS_VM_NAME`, `AZURE_AI_PROJECT_ENDPOINT`, `AZURE_AI_MODEL_DEPLOYMENT_NAME`,
  `SEED_ENABLE_SECOND_AGENT`, `SEED_SECOND_AGENT_MODEL`. Run `azd env refresh` if missing.
- Caller RBAC: permission to invoke VM run-commands (e.g. Virtual Machine Contributor).

### 3. Predown hook — capability-host cleanup (`hooks/predown.ps1`)
- Runs on the azd host **before** `azd down` deletes anything.
- A Foundry account/project with an **Agents capability host** cannot be deleted cleanly while
  the capability host exists, so the hook deletes it first, in strict order:
  **project-scope capability hosts, THEN account-scope** (`az resource delete` polls the
  long-running delete to completion before proceeding).
- Requires `AZURE_RESOURCE_GROUP`, `AZURE_AI_ACCOUNT_NAME`, `AZURE_AI_PROJECT_NAME` (Bicep
  outputs) plus `AZURE_SUBSCRIPTION_ID` (an azd built-in env var; falls back to
  `az account show`). Run `azd env refresh` if the Bicep outputs are missing.
- Best-effort by design: if Foundry was never provisioned it no-ops; if a real enumeration or
  delete error occurs it throws (with `continueOnError: false` this fails `azd down` early,
  which is correct — the teardown would fail anyway).
- Caller RBAC: permission to delete capability hosts (e.g. Cognitive Services Contributor).

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
- **Adding a new hook env var:** add a matching `output NAME ...` in `infra/main.bicep` (azd
  surfaces outputs as env vars verbatim; they are already UPPER_SNAKE), then read it in the hook.
- **`services:` is not yet defined in `azure.yaml`**, so `azd deploy`'s predeploy hook only fires
  once a service exists; `azd hooks run predeploy` works regardless. `predown` runs on any
  `azd down`.

## Optional: model gateway
`enableModelGateway=true` (default **false**) deploys an APIM-fronted provider Foundry and a
second seeded agent routed through it. See `apim-model-gateway.md`. Networking deep-dive:
`NETWORKING.md`.
