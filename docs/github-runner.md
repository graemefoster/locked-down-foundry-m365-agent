# Self-hosted GitHub Actions runner (in-VNet)

An **opt-in** self-hosted Actions runner on the in-VNet **Linux worker VM** so complex,
representative deployments can run *inside the VNet* — reaching the **private** Foundry
endpoint directly — instead of being marshalled through `az vm run-command`.

It is **off by default**: the runner is only installed when `githubRunnerRepoUrl`
(env var `GITHUB_RUNNER_REPO_URL`) is non-empty. Leave it unset and nothing changes.

## The two VMs

| VM | Module | When | Purpose |
|---|---|---|---|
| **Linux worker** (Ubuntu 24.04, `Standard_D2s_v6`) | `infra/stages/40-runner/resources/vm-linux.bicep` | **always** | Hosts the Actions runner, and is the `az vm run-command` target for agent seeding. Holds **all** the private-plane RBAC (Foundry, Key Vault, Contributor, OpenAI User). |
| **Windows dev VM** | `infra/stages/40-runner/resources/vm.bicep` | only when `deployWindowsVm` is true (**default false**) | Human-only: RDP in over Bastion and run Edge to inspect the environment behind the firewall. Holds **no** RBAC. |

Azure Bastion lives in its own module (`infra/stages/40-runner/resources/bastion.bicep`) and exists
purely for **interactive human access**. It is the only way into the Windows dev VM (RDP),
so it is gated by `deployBastion`, which **defaults to `deployWindowsVm`** — bring the
Windows VM up and Bastion comes with it. The Linux worker needs no interactive path (agent
seeding goes through `az vm run-command`, and the runner registers *outbound*), so the
default deployment gets neither. `azd up`'s preprovision hook prompts whether to deploy
the Windows VM; you can also set it non-interactively:

```bash
azd env set DEPLOY_WINDOWS_VM true   # opt in to the RDP box (and the Bastion to reach it)
```

`deployBastion` is deliberately **not** listed in `infra/main.parameters.json` (azd always
supplies params it finds there, which would hardcode a value and defeat the derived
default). If you want Bastion SSH into the Linux VM *without* the Windows VM, set
`deployBastion: true` explicitly in a `.bicepparam` or a direct `az deployment` call.

### Dependencies on the Linux VM

`infra/stages/40-runner/resources/cloud-init-linux-vm.yaml` installs everything at first boot:
`pwsh`, `azure-cli` (so `az acr build` covers container builds without a Docker daemon),
`python3`/`pip`/`venv` (the `microsoft/ai-agent-evals` action pip-installs into a venv),
plus `git`, `jq` and `yq`. That cloud-init file is the **only** shell script in the repo
— all downstream logic stays in cross-platform PowerShell.

Because the in-VNet runner is now Linux, two GitHub-hosted workarounds are gone:
`deploy-test-agent-one.yml` no longer needs a separate `ubuntu-latest` `prepare` job to
convert `agent.yaml` → `agent.json` (plus an artifact round-trip), and
`nightly-eval-agent-one.yml` consumes `microsoft/ai-agent-evals@v3-beta` directly instead
of checking the action out and invoking `action.py` by hand.

## Security model — "Posture A" (trusted-only)

The runner lives on a **persistent** VM that holds a managed identity (`vm-foundry-role`)
and has private-network reach, so it is a crown-jewel host. An ephemeral runner would
*not* make it safe — ephemeral only cleans the workspace, not the OS, and untrusted
code could still persist on the VM. Instead we guarantee **only trusted code ever runs
on it**:

| Control | Where |
|---|---|
| PR CI runs on **GitHub-hosted** runners only | `.github/workflows/ci.yml` (`runs-on: ubuntu-latest`) |
| VNet deploy has **no `pull_request` trigger** (dispatch only) | the per-agent `deploy-*-agent.yml` callers + reusable `.github/workflows/deploy-agent.yml` |
| VNet deploy is gated by a **required-reviewer environment** (Teams-publish / compliance jobs) | `environment: vnet-deploy` |
| `if: github.repository == ...` guard | `deploy-agent.yml` + each caller |

A fork PR can never select the self-hosted runner (label mismatch) and can never
invoke the deploy workflow (no PR trigger). The idle runner simply never picks up an
untrusted job.

## How auth works

The runner does not store a GitHub credential. The VM's **managed identity** reads a
**fine-grained PAT** from **Key Vault** (private data plane, over the VM's private DNS),
then mints a short-lived, single-use runner **registration token** to register once as a
**systemd** service.

The PAT is written into Key Vault by Bicep (`runner-pat-secret.bicep`) as an ARM
**control-plane** operation, which succeeds even though the vault has
`publicNetworkAccess=Disabled` (the KV firewall only governs the *data* plane). So no
in-VNet seeding, temporary roles, or `az vm run-command` are needed.

```
azd (GITHUB_RUNNER_PAT) --ARM control plane--> Key Vault secret gh-runner-pat
VM managed identity --(IMDS)--> KV token --> read PAT (data plane, private endpoint)
   --> POST /repos/{owner}/{repo}/actions/runners/registration-token
   --> config.sh --unattended + svc.sh install   (persistent, non-ephemeral)
```

Bootstrap: `infra/stages/40-runner/resources/bootstrap-github-runner.sh`, run on the VM as a
managed **Run Command** by `infra/stages/40-runner/resources/vm-runner-extension.bicep` (config is
injected as an `export` preamble; the PAT is never in the template). It blocks on
`cloud-init status --wait`, so it can never race the dependency install. The VM MI is
granted **Key Vault Secrets User** by `infra/stages/40-runner/rbac/vm-keyvault-secrets-role.bicep`,
and the Run Command is sequenced **after** both that assignment and the PAT-secret write.

## One-time setup

1. **Create a fine-grained PAT** on the repo with **Administration: read & write**
   (that scope gates the runner-token endpoints).

2. **Create the `vnet-deploy` Environment** (repo Settings → Environments):
   add yourself as a **required reviewer** and restrict deployment branches to `main`.

3. **Repo Settings → Actions → General:** require approval for **all outside
   collaborators'** fork-PR workflow runs; set the default `GITHUB_TOKEN` to read-only.

4. **Set the deploy-workflow repo variables.** The `postprovision` hook does this for you: after
   `azd provision` succeeds it runs `hooks/postprovision.ps1`, which pushes the relevant azd
   outputs into repo Settings → Secrets and variables → Actions → *Variables* via `gh variable set`
   (so the per-agent `deploy-*-agent.yml` and `deploy-compliancy.yml` workflows "just work"). It
   needs the GitHub CLI authenticated (`gh auth login`) with permission to write repo variables.
   Re-run it any time with `azd hooks run postprovision`.

   It syncs the same-named outputs (`AZURE_RESOURCE_GROUP`, `AZURE_AI_PROJECT_ENDPOINT`,
   `AZURE_AI_MODEL_DEPLOYMENT_NAME`, `MCP_COMPLIANCE_APIM_NAME`, `MCP_COMPLIANCE_AUDIENCE`,
   `TEAMS_*`) plus one rename — `MCP_SERVER_URL` ← `MCP_GATEWAY_URL`. `TEAMS_PUBLISH_SCOPE` has no
   output (it is an operator choice), so set it manually if you use Teams publishing.

   To set any variable by hand instead (e.g. from a different environment), mirror the azd output:

   ```bash
   gh variable set AZURE_AI_PROJECT_ENDPOINT --body "$(azd env get-value AZURE_AI_PROJECT_ENDPOINT)"
   gh variable set MCP_SERVER_URL --body "$(azd env get-value MCP_GATEWAY_URL)"
   ```

   You can also override any variable per-run via the workflow's dispatch inputs; the inputs take
   precedence over the variables.

## Enable it

`azd up`'s **preprovision hook** (`hooks/preprovision.ps1`) prompts once for the runner
repo URL (leave it blank to skip). Alternatively set it non-interactively:

```bash
azd env set GITHUB_RUNNER_REPO_URL https://github.com/<owner>/<repo>
azd env set GITHUB_RUNNER_PAT <fine-grained-PAT>   # written to Key Vault by Bicep
azd provision
# optional: clear the PAT from the local azd env — the KV secret persists
azd env set GITHUB_RUNNER_PAT ""
```

The **PAT is a secret and is never prompted** — supply it with `azd env set GITHUB_RUNNER_PAT`
before provisioning (the hook reminds you when you enter a repo URL without one set).

`GITHUB_RUNNER_PAT` is a `@secure()` param sourced from `${GITHUB_RUNNER_PAT}` (empty by
default). While set, it lives in the local, gitignored `.azure/<env>/.env`. Leaving it
empty on later provisions reuses the already-seeded Key Vault secret (the secret write is
conditional and ARM never deletes it).

On first provision the RBAC role assignment can take 1–5 min to propagate to the KV
data plane (same class of delay noted for CMK enablement). If the Run Command fails
reading the PAT, re-run `azd provision` — the bootstrap is idempotent (it skips if the
runner service already exists).

## Verify

- Repo → Settings → Actions → Runners shows an **Idle** runner with labels
  `vnet,foundry-private`.
- On the VM: `systemctl status 'actions.runner.*'` is **active (running)**.
- Run **Deploy (VNet self-hosted)** via *Actions → Run workflow*; approve the
  `vnet-deploy` gate; it seeds agents against the private endpoint using the VM MI.

## Teardown

`azd down`'s **predown hook** (`hooks/predown.ps1`) automatically deregisters the runner
before the VM is deleted, so it doesn't linger as a permanently **offline** runner in the
repo. It runs **host-side** with the GitHub CLI (`gh`) using your own credentials — no PAT,
no Key Vault and no VM round-trip. The runner name is deterministic (`<vmName>-vnet`, because
the bootstrap names it `<hostname>-vnet` and the VM's `computerName` is the VM name), so the
hook simply looks it up via `gh api .../actions/runners` and deletes it by id. This works
even when the VM's egress is locked down or the VM is already unhealthy.

This phase is **best-effort** and never fails the teardown — it only runs when
`GITHUB_RUNNER_REPO_URL` is set, and a lingering offline runner is harmless (GitHub prunes
it, or remove it manually under *Settings → Actions → Runners*). It relies on the
`GITHUB_RUNNER_REPO_URL` and `GITHUB_ACTIONS_RUNNER_VM_NAME` Bicep outputs (run
`azd env refresh` if they're missing) plus a host-side `gh` login with **admin** on the repo.
