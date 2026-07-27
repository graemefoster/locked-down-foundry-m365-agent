/*
Stage 10 slice — Model gateway platform.

The always-on enterprise model gateway substrate: the locked-down "provider"
Foundry that hosts the gateway model, the APIM Standard v2 instance, APIM's
inbound private endpoint, the provider Foundry private endpoints and the APIM->
provider role assignment.
*/

param location string
param uniqueSuffix string

// Provider Foundry + gateway-exposed model.
param providerAccountName string
param gatewayModelName string
param gatewayModelFormat string
param gatewayModelVersion string
param gatewayModelSkuName string
param gatewayModelCapacity int

param apimName string

// From stage 00.
param logAnalyticsId string
param appInsightsId string
param appInsightsConnectionString string
param modelGatewayApimSubnetId string
param modelGatewayPeSubnetId string
param hubVnetId string

// Provider AI Foundry (the "real" model provider) — minimal, locked-down.
module providerFoundry '../../modules/model-gateway/provider-foundry.bicep' = {
  name: 'provider-foundry-${uniqueSuffix}-deployment'
  params: {
    accountName: providerAccountName
    location: location
    modelName: gatewayModelName
    modelFormat: gatewayModelFormat
    modelVersion: gatewayModelVersion
    modelSkuName: gatewayModelSkuName
    modelCapacity: gatewayModelCapacity
    logAnalyticsWorkspaceId: logAnalyticsId
  }
}

// APIM Standard v2 in the gateway spoke. ALWAYS deployed (shared gateway).
module apim '../../modules/model-gateway/apim.bicep' = {
  name: 'model-gateway-apim-${uniqueSuffix}-deployment'
  params: {
    apimName: apimName
    location: location
    apimOutboundSubnetId: modelGatewayApimSubnetId
    logAnalyticsWorkspaceId: logAnalyticsId
    appInsightsResourceId: appInsightsId
    appInsightsConnectionString: appInsightsConnectionString
  }
}

// APIM inbound private endpoint + privatelink.azure-api.net DNS. ALWAYS deployed:
// callers (model-gateway connection AND the Teams inbound YARP path) reach APIM only
// through this PE once apim-lockdown flips publicNetworkAccess to 'Disabled'.
module apimPrivateEndpoint '../../modules/model-gateway/apim-private-endpoint.bicep' = {
  name: 'apim-pe-${uniqueSuffix}-deployment'
  params: {
    location: location
    suffix: uniqueSuffix
    apimId: apim.outputs.apimId
    apimName: apim.outputs.apimName
    peSubnetId: modelGatewayPeSubnetId
    hubVnetId: hubVnetId
  }
}

// Provider Foundry private endpoint + DNS in the gateway spoke (model gateway only).
module modelGatewayPrivateEndpoints '../../modules/model-gateway/model-gateway-private-endpoints.bicep' = {
  name: 'model-gateway-pe-${uniqueSuffix}-deployment'
  params: {
    location: location
    providerAccountId: providerFoundry.outputs.accountId
    providerAccountName: providerFoundry.outputs.accountName
    peSubnetId: modelGatewayPeSubnetId
  }
}

// Grant APIM MI Cognitive Services User on the provider Foundry (backend MI auth).
module apimProviderRoleAssignment '../../modules/model-gateway/apim-provider-role-assignment.bicep' = {
  name: 'model-gateway-apim-rbac-${uniqueSuffix}-deployment'
  params: {
    providerAccountName: providerFoundry.outputs.accountName
    apimPrincipalId: apim.outputs.apimPrincipalId
  }
}

// Model gateway
output providerAccountId string = providerFoundry.outputs.accountId
output apimName string = apim.outputs.apimName
output gatewayUrl string = apim.outputs.gatewayUrl

