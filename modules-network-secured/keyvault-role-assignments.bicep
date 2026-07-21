// Assigns Key Vault crypto roles to service identities for CMK

@description('Name of the Key Vault')
param keyVaultName string

@description('Principal ID of the AI Services account (SystemAssigned)')
param aiServicesPrincipalId string

@description('Principal ID of the Storage Account (SystemAssigned) - empty if BYO resource')
param storagePrincipalId string

@description('Principal ID of the AI Search service (SystemAssigned) - empty if BYO resource')
param aiSearchPrincipalId string

@description('Additional principal IDs to assign Key Vault Crypto User role (for service-managed identities used during CMK operations)')
param aiServicesProjectPrincipalId string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// Key Vault Crypto Service Encryption User: e147488a-f6f5-4113-8e2d-b22465e65bf6
// Only permits wrapKey/unwrapKey - sufficient for Storage, Search
resource kvCryptoServiceEncryptionUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'e147488a-f6f5-4113-8e2d-b22465e65bf6'
  scope: resourceGroup()
}

// Key Vault Crypto User: 12338af0-0e69-4776-bea7-57ae8d297424
// Includes sign/verify in addition to wrap/unwrap - required by AI Services
resource kvCryptoUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '12338af0-0e69-4776-bea7-57ae8d297424'
  scope: resourceGroup()
}

// AI Services - needs Crypto User (sign action required)
resource aiServicesRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(aiServicesPrincipalId, kvCryptoUserRole.id, keyVault.id)
  properties: {
    principalId: aiServicesPrincipalId
    roleDefinitionId: kvCryptoUserRole.id
    principalType: 'ServicePrincipal'
  }
}

// AI Services - needs Crypto User (sign action required)
resource aiServicesProjectRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(aiServicesProjectPrincipalId, kvCryptoUserRole.id, keyVault.id)
  properties: {
    principalId: aiServicesProjectPrincipalId
    roleDefinitionId: kvCryptoUserRole.id
    principalType: 'ServicePrincipal'
  }
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
