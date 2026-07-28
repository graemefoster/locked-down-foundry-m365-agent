// Assigns the Key Vault Crypto Service Encryption User role to the Storage and AI Search
// service identities for CMK. That role only permits wrapKey/unwrapKey, which is sufficient
// for Storage and Search. Split out of the shared keyvault-role-assignments module so the
// data resources' CMK grants live with the data substrate (stage 10); the account and project
// Crypto User grants live with the account (stage 13) and project (stage 15).

@description('Name of the Key Vault')
param keyVaultName string

@description('Principal ID of the Storage Account (SystemAssigned) - empty if BYO resource')
param storagePrincipalId string

@description('Principal ID of the AI Search service (SystemAssigned) - empty if BYO resource')
param aiSearchPrincipalId string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// Key Vault Crypto Service Encryption User: e147488a-f6f5-4113-8e2d-b22465e65bf6
// Only permits wrapKey/unwrapKey - sufficient for Storage, Search
resource kvCryptoServiceEncryptionUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'e147488a-f6f5-4113-8e2d-b22465e65bf6'
  scope: resourceGroup()
}

// Storage Account (skipped if BYO resource with empty principal ID)
resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(storagePrincipalId)) {
  scope: keyVault
  name: guid(storagePrincipalId, kvCryptoServiceEncryptionUserRole.id, keyVault.id)
  properties: {
    principalId: storagePrincipalId
    roleDefinitionId: kvCryptoServiceEncryptionUserRole.id
    principalType: 'ServicePrincipal'
  }
}

// AI Search (skipped if BYO resource with empty principal ID)
resource aiSearchRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(aiSearchPrincipalId)) {
  scope: keyVault
  name: guid(aiSearchPrincipalId, kvCryptoServiceEncryptionUserRole.id, keyVault.id)
  properties: {
    principalId: aiSearchPrincipalId
    roleDefinitionId: kvCryptoServiceEncryptionUserRole.id
    principalType: 'ServicePrincipal'
  }
}
