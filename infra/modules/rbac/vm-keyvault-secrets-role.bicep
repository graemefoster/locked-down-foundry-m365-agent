/*
  VM -> Key Vault Secrets User RBAC
  ---------------------------------
  Grants the Linux worker VM's system-assigned managed identity read access to Key
  Vault secrets, so the self-hosted GitHub Actions runner bootstrap
  (infra/modules/resources/bootstrap-github-runner.sh, run via a managed Run
  Command) can read the fine-grained PAT over the private KV data plane. Only
  wired when the runner is being installed.
*/

@description('Name of the Key Vault holding the runner PAT secret.')
param keyVaultName string

@description('Principal ID of the VM system-assigned managed identity.')
param vmPrincipalId string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// Key Vault Secrets User: 4633458b-17de-408a-b874-0445c86b69e6 (get/list secret values).
resource kvSecretsUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '4633458b-17de-408a-b874-0445c86b69e6'
  scope: subscription()
}

resource vmSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, vmPrincipalId, kvSecretsUserRole.id)
  properties: {
    principalId: vmPrincipalId
    roleDefinitionId: kvSecretsUserRole.id
    principalType: 'ServicePrincipal'
  }
}
