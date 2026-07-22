using './main.bicep'

param location = 'australiaeast'
param aiServices = 'aiservices'
param modelName = 'gpt-5.4'
param modelFormat = 'OpenAI'
param modelVersion = '2026-03-05'
param modelSkuName = 'GlobalStandard'
param modelCapacity = 30
param firstProjectName = 'project'

// ---- Optional model gateway (APIM Standard v2 + provider Foundry in a new spoke) ----
// Default false to avoid cost. Set true to deploy the enterprise model gateway.
param enableModelGateway = true

param gatewayModelName = 'gpt-5.4-mini'
param gatewayModelFormat = 'OpenAI'
param gatewayModelVersion = '2026-03-17'

param gatewayModelSkuName = 'GlobalStandard'
param gatewayModelCapacity = 30
// Optional: pin the calling app/client ID in the APIM validate-azure-ad-token policy.
// Leave empty to validate tenant + audience only (network boundary is the primary control).
param gatewayCallerAppId = ''
param projectDescription = 'A project for the AI Foundry account with network secured deployed Agent'
param displayName = 'project'
param peSubnetName = 'pe-subnet'

// Resource IDs for existing resources
// If you provide these, the deployment will use the existing resources instead of creating new ones
param vnetName = 'agent-vnet-test'
param agentSubnetName = 'agent-subnet'
param aiSearchResourceId = ''
param azureStorageAccountResourceId = ''
param azureCosmosDBAccountResourceId = ''

// Pass the DNS zone map here
// Leave empty to create new DNS zone, add the resource group of existing DNS zone to use it
param existingDnsZones = {
  'privatelink.services.ai.azure.com': ''
  'privatelink.openai.azure.com': ''
  'privatelink.cognitiveservices.azure.com': ''               
  'privatelink.search.windows.net': ''           
  'privatelink.blob.core.windows.net': ''                            
  'privatelink.documents.azure.com': ''
  'privatelink.azure-api.net': ''
  'privatelink.vaultcore.azure.net': ''
  'privatelink.azurecr.io': ''
}

//DNSZones names for validating if they exist
param dnsZoneNames = [
  'privatelink.services.ai.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.cognitiveservices.azure.com'
  'privatelink.search.windows.net'
  'privatelink.blob.core.windows.net'
  'privatelink.documents.azure.com'
  'privatelink.azure-api.net'
  'privatelink.vaultcore.azure.net'
  'privatelink.azurecr.io'

]

param vmAdminUsername = 'graeme'
// DO NOT commit a real password here. Pass at deploy time:
//   az deployment group create ... --parameters vmAdminPassword='<your-password>'
param vmAdminPassword = 'sdfkjh8789*(&876234basdghui)'

