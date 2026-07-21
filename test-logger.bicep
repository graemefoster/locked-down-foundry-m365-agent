resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = { name: 'test' }
resource apimAppInsightsLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights-logger'
  properties: {
    loggerType: 'applicationInsights'
    resourceId: 'test'
    credentials: {
      connectionString: 'test'
    }
  }
}
