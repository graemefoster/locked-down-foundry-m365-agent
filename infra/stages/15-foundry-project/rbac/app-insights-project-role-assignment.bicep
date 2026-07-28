// Assigns the Reader role to the Foundry project identity on Application Insights.
// This supports running Foundry Agent continuous evaluations on existing traces.
// Split out of the shared app-insights-role-assignment module so the project's grant
// lives in the same stage as the project. The account's Log Analytics Reader grant
// lives in stage 13 with the account.

@description('Application Insights resource name')
param appInsightsName string

@description('Principal ID of the AI project managed identity')
param projectPrincipalId string

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

// Reader: acdd72a7-3385-48ef-bd42-f606fba81ae7
resource readerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  scope: resourceGroup()
}

resource appInsightsReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appInsights
  name: guid(projectPrincipalId, readerRole.id, appInsights.id)
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: readerRole.id
    principalType: 'ServicePrincipal'
  }
}
