// Assigns the Key Vault Crypto User role to the Foundry (AI Services) account identity
// for CMK. AI Services needs Crypto User (not just Crypto Service Encryption User) because
// the sign action is required. Split out of the shared keyvault-role-assignments module so
// the account's CMK grant lives in the same stage as the account it protects.

@description('Name of the Key Vault')
param keyVaultName string

@description('Principal ID of the AI Services account (SystemAssigned)')
param aiServicesPrincipalId string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// Key Vault Crypto User: 12338af0-0e69-4776-bea7-57ae8d297424
// Includes sign/verify in addition to wrap/unwrap - required by AI Services
resource kvCryptoUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '12338af0-0e69-4776-bea7-57ae8d297424'
  scope: resourceGroup()
}

resource aiServicesRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(aiServicesPrincipalId, kvCryptoUserRole.id, keyVault.id)
  properties: {
    principalId: aiServicesPrincipalId
    roleDefinitionId: kvCryptoUserRole.id
    principalType: 'ServicePrincipal'
  }
}
