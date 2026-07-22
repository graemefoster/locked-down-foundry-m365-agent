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

param vnetName = 'agent-vnet-test'
param agentSubnetName = 'agent-subnet'

param vmAdminUsername = 'graeme'
// DO NOT commit a real password here. Pass at deploy time:
//   az deployment group create ... --parameters vmAdminPassword='<your-password>'
param vmAdminPassword = 'sdfkjh8789*(&876234basdghui)'

