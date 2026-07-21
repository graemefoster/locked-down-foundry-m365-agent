// Updates the AI Services account with CMK encryption after RBAC is assigned

@description('Name of the AI Services account')
param accountName string

@description('Location for the resource')
param location string

@description('Key Vault URI')
param keyVaultUri string

@description('Key name in the Key Vault')
param keyName string

@description('Key version in the Key Vault')
param keyVersion string

@description('Agent subnet resource ID for network injection')
param agentSubnetId string

@description('Key Vault name (used to construct FQDN for allowed outbound list)')
param keyVaultName string

resource existingAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

#disable-next-line BCP036
resource accountUpdate 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: existingAccount.name
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  properties: {
    encryption: {
      keySource: 'Microsoft.KeyVault'
      keyVaultProperties: {
        keyVaultUri: keyVaultUri
        keyName: keyName
        keyVersion: keyVersion
      }
    }
    allowProjectManagement: true
    customSubDomainName: accountName
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: false
    restrictOutboundNetworkAccess: true
    allowedFqdnList: [
      '${keyVaultName}.vault.azure.net'
    ]
    networkAcls: {
      defaultAction: 'Allow'
      virtualNetworkRules: []
      ipRules: []
      bypass: 'AzureServices'
    }
    networkInjections: [
      {
        scenario: 'agent'
        subnetArmId: agentSubnetId
        useMicrosoftManagedNetwork: false
      }
    ]
  }
}
