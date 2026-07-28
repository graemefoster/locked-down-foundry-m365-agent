/*
  Model-Gateway: APIM MI → provider Foundry role assignments
  ---------------------------------------------------------
  Grants the APIM system-assigned managed identity:
    * Cognitive Services User — data-plane inference: the
      authentication-managed-identity backend policy acquires a token and calls
      the provider's inference endpoint.
    * Reader — ARM control-plane read: the dynamic model-discovery operations
      (GET /deployments) call the Azure Resource Manager deployments API of the
      provider account, which requires the read action on
      Microsoft.CognitiveServices/accounts/deployments (covered by Reader, which
      grants read on all sub-resources at account scope).

  Role GUIDs:
    Cognitive Services User: a97b65f3-24c7-4388-baec-2e87135dc908
    Reader:                  acdd72a7-3385-48ef-bd42-f606fba81ae7
  (Cognitive Services User matches the foundry-samples byom-cross-region reference.)
*/

@description('Name of the provider Foundry (Cognitive Services) account')
param providerAccountName string

@description('Principal (object) ID of the APIM system-assigned managed identity')
param apimPrincipalId string

var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource providerAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: providerAccountName
}

resource apimToProviderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: providerAccount
  name: guid(providerAccount.id, apimPrincipalId, cognitiveServicesUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ARM control-plane read for dynamic model discovery (GET /deployments).
resource apimToProviderReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: providerAccount
  name: guid(providerAccount.id, apimPrincipalId, readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}
