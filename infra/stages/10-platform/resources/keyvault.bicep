// Creates an Azure Key Vault with RBAC authorization for CMK encryption

@description('Name of the Key Vault')
param keyVaultName string

@description('Azure region of the deployment')
param location string

@description('Log Analytics Workspace ID for diagnostics')
param logAnalyticsId string

@description('Name of the CMK encryption key to create')
param keyName string = 'cmk-encryption-key'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
}

resource encryptionKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  parent: keyVault
  name: keyName
  properties: {
    kty: 'RSA'
    keySize: 3072
    attributes: {
      enabled: true
    }
    rotationPolicy: {
      attributes: {
        expiryTime: 'P2Y'
      }
      lifetimeActions: [
        {
          action: { type: 'rotate' }
          trigger: { timeBeforeExpiry: 'P90D' }
        }
        {
          action: { type: 'notify' }
          trigger: { timeBeforeExpiry: 'P30D' }
        }
      ]
    }
  }
}

resource kvDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: keyVault
  name: 'diagnostics'
  properties: {
    workspaceId: logAnalyticsId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri
output keyName string = encryptionKey.name
output keyUri string = encryptionKey.properties.keyUri
output keyUriWithVersion string = encryptionKey.properties.keyUriWithVersion
