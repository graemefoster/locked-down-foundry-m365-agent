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

@description('Restrict outbound network access to the allowedFqdnList. Shared with the identity module so both full-PUT declarations of the account agree.')
param restrictOutboundNetworkAccess bool

@description('Allowed outbound FQDNs (only enforced when restrictOutboundNetworkAccess is true). Shared with the identity module.')
param allowedFqdnList array

@description('Public network access on the Foundry account data plane (Disabled = firewall tier, Enabled = firewall opt-out on-ramp). Shared with the identity module so both full-PUT declarations agree.')
param publicNetworkAccess string = 'Disabled'

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
    publicNetworkAccess: publicNetworkAccess
    disableLocalAuth: false
    restrictOutboundNetworkAccess: restrictOutboundNetworkAccess
    // allowedFqdnList only applies when restrictOutboundNetworkAccess is true. Egress is left
    // unrestricted (network isolation is still enforced via publicNetworkAccess: Disabled +
    // networkInjections + private endpoints), so no FQDN allow-list is needed for CMK/Key Vault.
    allowedFqdnList: allowedFqdnList
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
