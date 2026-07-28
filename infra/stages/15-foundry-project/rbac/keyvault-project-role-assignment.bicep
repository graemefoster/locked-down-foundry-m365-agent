// Assigns the Key Vault Crypto User role to the Foundry project identity for CMK.
// Split out of the shared keyvault-role-assignments module so the project's CMK grant
// lives in the same stage as the project.

@description('Name of the Key Vault')
param keyVaultName string

@description('Principal ID of the AI project (SystemAssigned)')
param projectPrincipalId string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// Key Vault Crypto User: 12338af0-0e69-4776-bea7-57ae8d297424
// Includes sign/verify in addition to wrap/unwrap - required by AI Services
resource kvCryptoUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '12338af0-0e69-4776-bea7-57ae8d297424'
  scope: resourceGroup()
}

resource projectRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(projectPrincipalId, kvCryptoUserRole.id, keyVault.id)
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: kvCryptoUserRole.id
    principalType: 'ServicePrincipal'
  }
}
