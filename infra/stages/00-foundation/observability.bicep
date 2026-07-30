/*
Stage 00 slice — Observability sink.
Where everything logs: Log Analytics workspace + Application Insights. No dependencies.
*/

param location string
param logAnalyticsName string
param appInsightsName string

resource lanalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  kind: 'web'
  location: location
  name: appInsightsName
  properties: {
    Application_Type: 'web'
    Flow_Type: 'BlueField'
    WorkspaceResourceId: lanalytics.id
    RetentionInDays: 30
    #disable-next-line BCP037
    CustomMetricsOptedInType: 'WithDimensions'
  }
}

output logAnalyticsId string = lanalytics.id
output logAnalyticsCustomerId string = lanalytics.properties.customerId
output appInsightsId string = appInsights.id
output appInsightsConnectionString string = appInsights.properties.ConnectionString
