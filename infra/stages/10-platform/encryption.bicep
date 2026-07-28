/*
Stage 10 slice — CMK RBAC & encryption.
Grants Key Vault Crypto Service Encryption User to the AI Services / project /
storage / search identities, THEN re-PUTs the Foundry account and Storage account
with customer-managed-key encryption. Both encryption modules depend on the role
assignment (KV data-plane role must be effective first). The account CMK re-PUT
mirrors the account's egress posture so the two PUTs never drift.
*/

param location string
param uniqueSuffix string

param keyVaultName string
param keyVaultUri string
param keyName string
param keyUriWithVersion string

// Foundry account (from foundry-account slice).
param accountName string
param accountPrincipalId string

// Dependent-resource identities (from data-resources slice).
param azureStorageName string
param storagePrincipalId string
param aiSearchPrincipalId string

// Project identity (from project slice).
param projectPrincipalId string

// From stage 00.
param agentSubnetId string

// Shared egress posture (defined once in the orchestrator, passed to account + encryption).
param restrictOutboundNetworkAccess bool
param allowedFqdnList array

// Storage SKU (computed in main — stage 00 needs it too — threaded here).
param storageSkuName string

// Assign Key Vault Crypto Service Encryption User to service identities (post-creation)
module keyVaultRoleAssignments './rbac/keyvault-role-assignments.bicep' = {
  name: 'keyvault-rbac-${uniqueSuffix}-deployment'
  params: {
    keyVaultName: keyVaultName
    aiServicesPrincipalId: accountPrincipalId
    storagePrincipalId: storagePrincipalId
    aiSearchPrincipalId: aiSearchPrincipalId
    aiServicesProjectPrincipalId: projectPrincipalId
  }
}

// Update AI Services account with CMK encryption (must be after RBAC assignment)
module aiAccountEncryption './encryption/ai-account-encryption.bicep' = {
  name: 'ai-encryption-${uniqueSuffix}-deployment'
  params: {
    accountName: accountName
    location: location
    keyVaultUri: keyVaultUri
    keyName: keyName
    keyVersion: last(split(keyUriWithVersion, '/'))
    agentSubnetId: agentSubnetId
    restrictOutboundNetworkAccess: restrictOutboundNetworkAccess
    allowedFqdnList: allowedFqdnList
  }
  dependsOn: [
    keyVaultRoleAssignments
  ]
}

// Update Storage Account with CMK encryption (must be after RBAC assignment)
module storageEncryption './encryption/storage-encryption.bicep' = {
  name: 'storage-encryption-${uniqueSuffix}-deployment'
  params: {
    storageName: azureStorageName
    location: location
    keyVaultUri: keyVaultUri
    keyVaultKeyName: keyName
    skuName: storageSkuName
  }
  dependsOn: [
    keyVaultRoleAssignments
  ]
}
