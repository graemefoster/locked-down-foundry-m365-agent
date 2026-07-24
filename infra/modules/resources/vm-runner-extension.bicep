/*
  Self-hosted GitHub Actions runner — CustomScriptExtension.
  ----------------------------------------------------------
  Kept as its own module (separate from vm.bicep) so main.bicep can sequence it
  AFTER the VM's Key Vault Secrets User role assignment: the on-VM bootstrap reads
  the runner PAT from Key Vault via the VM managed identity, so that RBAC must
  exist first (avoids the circular dependency you'd get embedding this in vm.bicep,
  where the role assignment already needs the VM's principalId).

  The bootstrap script is embedded (base64) at compile time and decoded on the VM,
  so no external file hosting is required. No secret transits azd or the template —
  the PAT is only ever read from Key Vault in-memory on the VM.
*/

@description('Name of the existing VM to install the runner on.')
param vmName string

@description('Location for the extension.')
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

var runnerScriptB64 = base64(loadTextContent('bootstrap-github-runner.ps1'))
var runnerCommand = 'powershell -ExecutionPolicy Bypass -NoProfile -Command "[IO.File]::WriteAllText(\'C:\\bootstrap-github-runner.ps1\', [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'${runnerScriptB64}\'))); & \'C:\\bootstrap-github-runner.ps1\' -RepoUrl \'${githubRunnerRepoUrl}\' -KeyVaultName \'${keyVaultName}\' -PatSecretName \'${githubRunnerPatSecretName}\' -RunnerLabels \'${githubRunnerLabels}\'"'

resource runnerExtension 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vm
  name: 'install-github-runner'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: runnerCommand
    }
  }
}
