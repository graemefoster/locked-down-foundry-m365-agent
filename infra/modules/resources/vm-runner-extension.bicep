/*
  Self-hosted GitHub Actions runner — managed Run Command.
  --------------------------------------------------------
  Kept as its own module (separate from vm.bicep) so main.bicep can sequence it
  AFTER the VM's Key Vault Secrets User role assignment: the on-VM bootstrap reads
  the runner PAT from Key Vault via the VM managed identity, so that RBAC must
  exist first (avoids the circular dependency you'd get embedding this in vm.bicep,
  where the role assignment already needs the VM's principalId).

  The bootstrap script is embedded via loadTextContent() and delivered as the Run
  Command's `source.script` (the script CONTENT, not a command line). This avoids
  the legacy CustomScriptExtension's cmd.exe `commandToExecute` length limit
  (~8191 chars): the script is >8 KB, whose base64 alone exceeds that limit, so the
  old extension could never provision. No external file hosting is required and no
  secret transits azd or the template — the PAT is only ever read from Key Vault
  in-memory on the VM.

  Parameters are passed to the PowerShell script by name (Windows managed Run
  Command runs `bootstrap.ps1 -RepoUrl <v> -KeyVaultName <v> ...`). The script also
  normalizes -RunnerLabels defensively, since the comma-separated value can be split
  by PowerShell argument parsing.
*/

@description('Name of the existing VM to install the runner on.')
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

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: vmName
}

resource runnerRunCommand 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'install-github-runner'
  location: location
  properties: {
    source: {
      script: loadTextContent('bootstrap-github-runner.ps1')
    }
    parameters: [
      { name: 'RepoUrl', value: githubRunnerRepoUrl }
      { name: 'KeyVaultName', value: keyVaultName }
      { name: 'PatSecretName', value: githubRunnerPatSecretName }
      { name: 'RunnerLabels', value: githubRunnerLabels }
    ]
    // Run synchronously and surface a non-zero script exit as a deployment failure,
    // preserving the fail-fast behaviour the old CustomScriptExtension had.
    asyncExecution: false
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
}
