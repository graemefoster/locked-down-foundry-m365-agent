// Updates Storage Account with CMK encryption after RBAC is assigned

@description('Name of the Storage Account')
param storageName string

@description('Location for the resource')
param location string

@description('Key Vault URI')
param keyVaultUri string

@description('Key name in the Key Vault')
param keyVaultKeyName string

@description('Storage account SKU name')
param skuName string

@description('Firewall opt-out tier flag — carried so the CMK re-PUT restates the same SecurityControl tag as the initial declaration (a Storage PUT must agree or the tag/network posture can drift).')
param deployFirewall bool

resource existingStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageName
}

resource storageUpdate 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: existingStorage.name
  location: location
  kind: 'StorageV2'
  tags: deployFirewall ? {} : { SecurityControl: 'Ignore' }
  sku: {
    name: skuName
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    encryption: {
      keySource: 'Microsoft.Keyvault'
      keyvaultproperties: {
        keyvaulturi: keyVaultUri
        keyname: keyVaultKeyName
      }
      services: {
        blob: { enabled: true }
        file: { enabled: true }
        queue: { enabled: true }
        table: { enabled: true }
      }
    }
  }
}
