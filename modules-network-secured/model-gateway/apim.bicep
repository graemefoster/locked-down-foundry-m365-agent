/*
  Model-Gateway: APIM Standard v2
  -------------------------------
  Standard v2 API Management instance that fronts the provider AI Foundry.

    * Outbound VNet integration into the model-gateway spoke's apim-subnet
      (virtualNetworkType 'External' + virtualNetworkConfiguration.subnetResourceId),
      so APIM can reach the provider Foundry over its private endpoint.
    * Inbound access is locked down: publicNetworkAccess = 'Disabled'. The primary
      Foundry project reaches the gateway through an inbound private endpoint
      (created in model-gateway-private-endpoints.bicep), force-tunnelled via the
      Azure Firewall.
    * System-assigned managed identity — used to authenticate to the provider
      Foundry backend (authentication-managed-identity policy) and validated as the
      caller's identity is the primary project MI.

  Sources:
    - APIM v2 outbound VNet integration: https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound
    - APIM inbound private endpoint (v2): https://learn.microsoft.com/azure/api-management/private-endpoint
*/

@description('Name of the APIM instance')
param apimName string

@description('Azure region — must match the VNet region')
param location string

@description('Publisher email for the APIM instance')
param publisherEmail string = 'noreply@microsoft.com'

@description('Publisher name for the APIM instance')
param publisherName string = 'Model Gateway'

@description('Capacity (scale units) for the Standard v2 SKU')
param skuCapacity int = 1

@description('Resource ID of the delegated subnet used for outbound VNet integration')
param apimOutboundSubnetId string

@description('Log Analytics workspace resource ID for diagnostics')
param logAnalyticsWorkspaceId string

@description('Resource ID of the existing Application Insights component to send gateway telemetry to')
param appInsightsResourceId string

@description('Connection string of the existing Application Insights component')
@secure()
param appInsightsConnectionString string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  sku: {
    name: 'StandardV2'
    capacity: skuCapacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    // Outbound VNet integration ('External' = outbound-only integration, not full injection).
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: apimOutboundSubnetId
    }
    // Inbound is via a private endpoint only; block public gateway ingress.
    publicNetworkAccess: 'Disabled'
  }
}

resource apimDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: apim
  name: 'diagnostics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// APIM → Application Insights integration (gateway request/response telemetry).
// A logger of type 'applicationInsights' points at the existing App Insights component,
// and a service-scoped diagnostic named 'applicationinsights' (well-known name) wires
// the gateway pipeline to it.
resource apimAppInsightsLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights-logger'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for the model gateway'
    resourceId: appInsightsResourceId
    credentials: {
      connectionString: appInsightsConnectionString
    }
  }
}

resource apimAppInsightsDiagnostic 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerId: apimAppInsightsLogger.id
    alwaysLog: 'allErrors'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    logClientIp: true
  }
}

output apimName string = apim.name
output apimId string = apim.id
output apimPrincipalId string = apim.identity.principalId
output gatewayUrl string = apim.properties.gatewayUrl
