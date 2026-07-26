# Self-hosted GitHub Actions runner (in-VNet)

An **opt-in** self-hosted Actions runner on the in-VNet **Linux worker VM** so complex,
representative deployments can run *inside the VNet* — reaching the **private** Foundry
endpoint directly — instead of being marshalled through `az vm run-command`.

It is **off by default**: the runner is only installed when `githubRunnerRepoUrl`
(env var `GITHUB_RUNNER_REPO_URL`) is non-empty. Leave it unset and nothing changes.

## The two VMs

| VM | Module | When | Purpose |
|---|---|---|---|
| **Linux worker** (Ubuntu 24.04, `Standard_D2s_v6`) | `infra/modules/resources/vm-linux.bicep` | **always** | Hosts the Actions runner, and is the `az vm run-command` target for agent seeding. Holds **all** the private-plane RBAC (Foundry, Key Vault, Contributor, OpenAI User). |
| **Windows dev VM** | `infra/modules/resources/vm.bicep` | only when `deployWindowsVm` is true | Human-only: RDP in over Bastion and run Edge to inspect the environment behind the firewall. Holds **no** RBAC. |

Azure Bastion lives in its own module (`infra/modules/resources/bastion.bicep`) and exists
purely for **interactive human access**. It is the only way into the Windows dev VM (RDP),
so it is gated by `deployBastion`, which **defaults to `deployWindowsVm`** — turn the
Windows VM off and Bastion goes with it. The Linux worker needs no interactive path (agent
seeding goes through `az vm run-command`, and the runner registers *outbound*), so a
CI-only environment gets neither:

```bash
azd env set DEPLOY_WINDOWS_VM false   # CI-only: skip the Windows licence + compute, and Bastion
```

`deployBastion` is deliberately **not** listed in `infra/main.parameters.json` (azd always
supplies params it finds there, which would hardcode a value and defeat the derived
default). If you want Bastion SSH into the Linux VM *without* the Windows VM, set
`deployBastion: true` explicitly in a `.bicepparam` or a direct `az deployment` call.

### Dependencies on the Linux VM

`infra/modules/resources/cloud-init-linux-vm.yaml` installs everything at first boot:
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
| VNet deploy has **no `pull_request` trigger** (dispatch only) | `.github/workflows/deploy-vnet.yml` |
| VNet deploy is gated by a **required-reviewer environment** | `environment: vnet-deploy` |
| `if: github.repository == ...` guard | `deploy-vnet.yml` |

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

Bootstrap: `infra/modules/resources/bootstrap-github-runner.sh`, run on the VM as a
managed **Run Command** by `infra/modules/resources/vm-runner-extension.bicep` (config is
injected as an `export` preamble; the PAT is never in the template). It blocks on
`cloud-init status --wait`, so it can never race the dependency install. The VM MI is
granted **Key Vault Secrets User** by `infra/modules/rbac/vm-keyvault-secrets-role.bicep`,
and the Run Command is sequenced **after** both that assignment and the PAT-secret write.

## One-time setup

1. **Create a fine-grained PAT** on the repo with **Administration: read & write**
   (that scope gates the runner-token endpoints).

2. **Create the `vnet-deploy` Environment** (repo Settings → Environments):
   add yourself as a **required reviewer** and restrict deployment branches to `main`.

3. **Repo Settings → Actions → General:** require approval for **all outside
   collaborators'** fork-PR workflow runs; set the default `GITHUB_TOKEN` to read-only.

4. **Set the deploy-workflow repo variables** (repo Settings → Secrets and variables →
   Actions → *Variables*) so `deploy-vnet.yml` knows what to seed — these mirror the azd
   outputs of the target environment:

   | Variable | Value | Source |
   |---|---|---|
   | `AZURE_AI_PROJECT_ENDPOINT` | e.g. `https://<aiservices>.services.ai.azure.com/api/projects/<project>` | `azd env get-value AZURE_AI_PROJECT_ENDPOINT` |
   | `AZURE_AI_MODEL_DEPLOYMENT_NAME` | e.g. `gpt-5.4` | `azd env get-value AZURE_AI_MODEL_DEPLOYMENT_NAME` |

   ```bash
   gh variable set AZURE_AI_PROJECT_ENDPOINT --body "$(azd env get-value AZURE_AI_PROJECT_ENDPOINT)"
   gh variable set AZURE_AI_MODEL_DEPLOYMENT_NAME --body "$(azd env get-value AZURE_AI_MODEL_DEPLOYMENT_NAME)"
   ```

   You can also override either per-run via the workflow's dispatch inputs; the inputs take
   precedence over the variables.

## Enable it

```bash
azd env set GITHUB_RUNNER_REPO_URL https://github.com/<owner>/<repo>
azd env set GITHUB_RUNNER_PAT <fine-grained-PAT>   # written to Key Vault by Bicep
azd provision
# optional: clear the PAT from the local azd env — the KV secret persists
azd env set GITHUB_RUNNER_PAT ""
```

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
