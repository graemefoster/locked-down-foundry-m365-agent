@description('Name of the AI Services account hosting the embedding deployment.')
param accountName string

@description('Principal ID of the Azure AI Search system-assigned managed identity.')
param aiSearchPrincipalId string

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource openAiUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  scope: subscription()
}

resource aiSearchOpenAiUserOnAccount 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, aiSearchPrincipalId, openAiUserRole.id)
  properties: {
    principalId: aiSearchPrincipalId
    roleDefinitionId: openAiUserRole.id
    principalType: 'ServicePrincipal'
  }
}
