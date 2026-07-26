/*
  Self-hosted GitHub Actions runner — managed Run Command (Linux).
  ---------------------------------------------------------------
  Kept as its own module (separate from vm-linux.bicep) so main.bicep can sequence
  it AFTER the VM's Key Vault Secrets User role assignment: the on-VM bootstrap
  reads the runner PAT from Key Vault via the VM managed identity, so that RBAC
  must exist first (avoids the circular dependency you'd get embedding this in the
  VM module, where the role assignment already needs the VM's principalId).

  The bootstrap script is embedded via loadTextContent() and delivered as the Run
  Command's `source.script` (the script CONTENT, not a command line), so no
  external file hosting is required and no secret transits azd or the template —
  the PAT is only ever read from Key Vault in-memory on the VM.

  Config is passed by prepending an `export` preamble to the script rather than
  using the Run Command `parameters` array: on Linux those are positional shell
  arguments (not the named PowerShell parameters the Windows agent produces), so
  an explicit preamble is unambiguous. None of these values are secrets.
*/

@description('Name of the existing Linux VM to install the runner on.')
param vmName string

@description('Location for the Run Command.')
param location string = resourceGroup().location

@description('GitHub repo URL, e.g. https://github.com/owner/repo.')
param githubRunnerRepoUrl string

@description('Key Vault (DNS) name holding the runner PAT secret.')
param keyVaultName string

@description('Name of the Key Vault secret holding the fine-grained PAT.')
param githubRunnerPatSecretName string

@description('Comma-separated labels applied to the self-hosted runner.')
param githubRunnerLabels string

@description('Local account the runner service runs as (the VM admin user). The runner refuses to run as root.')
param runnerUser string

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: vmName
}

var configPreamble = join(
  [
    '#!/usr/bin/env bash'
    'export REPO_URL=\'${githubRunnerRepoUrl}\''
    'export KEY_VAULT_NAME=\'${keyVaultName}\''
    'export PAT_SECRET_NAME=\'${githubRunnerPatSecretName}\''
    'export RUNNER_LABELS=\'${githubRunnerLabels}\''
    'export RUNNER_USER=\'${runnerUser}\''
    ''
  ],
  '\n'
)

resource runnerRunCommand 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'install-github-runner'
  location: location
  properties: {
    source: {
      script: '${configPreamble}${loadTextContent('bootstrap-github-runner.sh')}'
    }
    // Run synchronously and surface a non-zero script exit as a deployment failure,
    // so a broken runner install fails `azd provision` rather than passing silently.
    asyncExecution: false
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
}
