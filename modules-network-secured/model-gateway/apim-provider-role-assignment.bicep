/*
  Model-Gateway: APIM MI → provider Foundry role assignment
  ---------------------------------------------------------
  Grants the APIM system-assigned managed identity the Cognitive Services User
  role on the provider Foundry account, so the authentication-managed-identity
  backend policy can acquire a token and call the provider's inference endpoint.

  Role GUID (Cognitive Services User): a97b65f3-24c7-4388-baec-2e87135dc908
  (matches the foundry-samples byom-cross-region reference.)
*/

@description('Name of the provider Foundry (Cognitive Services) account')
param providerAccountName string

@description('Principal (object) ID of the APIM system-assigned managed identity')
param apimPrincipalId string

var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'

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
