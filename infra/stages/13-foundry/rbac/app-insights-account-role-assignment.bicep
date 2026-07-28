// Assigns the Log Analytics Reader role to the Foundry (AI Services) account identity on
// Application Insights. Split out of the shared app-insights-role-assignment module so the
// account's grant lives in the same stage as the account. The project's Reader grant lives
// in stage 15 with the project.

@description('Application Insights resource name')
param appInsightsName string

@description('Principal ID of the AI account managed identity')
param accountPrincipalId string

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

// Log Analytics Reader: 73c42c96-874c-492b-b04d-ab87d138a893
resource logAnalyticsReaderRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '73c42c96-874c-492b-b04d-ab87d138a893'
  scope: resourceGroup()
}

resource appInsightsLogAnalyticsReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appInsights
  name: guid(accountPrincipalId, logAnalyticsReaderRole.id, appInsights.id)
  properties: {
    principalId: accountPrincipalId
    roleDefinitionId: logAnalyticsReaderRole.id
    principalType: 'ServicePrincipal'
  }
}
