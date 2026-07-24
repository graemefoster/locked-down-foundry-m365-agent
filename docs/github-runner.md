# Self-hosted GitHub Actions runner (in-VNet)

An **opt-in** self-hosted Actions runner on the dev VM so complex, representative
deployments can run *inside the VNet* — reaching the **private** Foundry endpoint
directly — instead of being marshalled through `az vm run-command`.

It is **off by default**: the runner is only installed when `githubRunnerRepoUrl`
(env var `GITHUB_RUNNER_REPO_URL`) is non-empty. Leave it unset and nothing changes.

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
Windows service.

The PAT is written into Key Vault by Bicep (`runner-pat-secret.bicep`) as an ARM
**control-plane** operation, which succeeds even though the vault has
`publicNetworkAccess=Disabled` (the KV firewall only governs the *data* plane). So no
in-VNet seeding, temporary roles, or `az vm run-command` are needed.

```
azd (GITHUB_RUNNER_PAT) --ARM control plane--> Key Vault secret gh-runner-pat
VM managed identity --(IMDS)--> KV token --> read PAT (data plane, private endpoint)
   --> POST /repos/{owner}/{repo}/actions/runners/registration-token
   --> config.cmd --runasservice   (persistent, non-ephemeral)
```

Bootstrap: `infra/modules/resources/bootstrap-github-runner.ps1`, embedded (base64) into
a `CustomScriptExtension` by `infra/modules/resources/vm-runner-extension.bicep`. The VM
MI is granted **Key Vault Secrets User** by `infra/modules/rbac/vm-keyvault-secrets-role.bicep`,
and the extension is sequenced **after** both that assignment and the PAT-secret write.

## One-time setup

1. **Create a fine-grained PAT** on the repo with **Administration: read & write**
   (that scope gates the runner-token endpoints).

2. **Create the `vnet-deploy` Environment** (repo Settings → Environments):
   add yourself as a **required reviewer** and restrict deployment branches to `main`.

3. **Repo Settings → Actions → General:** require approval for **all outside
   collaborators'** fork-PR workflow runs; set the default `GITHUB_TOKEN` to read-only.

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
data plane (same class of delay noted for CMK enablement). If the extension fails
reading the PAT, re-run `azd provision` — the bootstrap is idempotent (it skips if the
runner service already exists).

## Verify

- Repo → Settings → Actions → Runners shows an **Idle** runner with labels
  `vnet,foundry-private`.
- On the VM: `Get-Service actions.runner.*` is **Running**.
- Run **Deploy (VNet self-hosted)** via *Actions → Run workflow*; approve the
  `vnet-deploy` gate; it seeds agents against the private endpoint using the VM MI.
