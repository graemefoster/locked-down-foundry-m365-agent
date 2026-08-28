/*
Foundry project — a sub-resource of the AI Services account (Microsoft.CognitiveServices/
accounts/projects). Despite living under foundry/, this creates the WHOLE project, not just
an identity:
  - the project resource + its own system-assigned managed identity (the project data-plane
    identity that agents run as)
  - the BYO ("bring your own") connections wiring the project to the dependent resources it
    stores agent state in: Azure Storage (files), CosmosDB (threads/messages), AI Search
    (vector store)
  - project diagnostic settings -> Log Analytics

The project can't actually USE those connections until the data-plane RBAC + the Agents
capability host are in place — see the rest of stage 15.
*/

param accountName string
param location string
param projectName string
param projectDescription string
param displayName string

param aiSearchName string
param aiSearchServiceResourceGroupName string
param aiSearchServiceSubscriptionId string

param cosmosDBName string
param cosmosDBSubscriptionId string
param cosmosDBResourceGroupName string

param azureStorageName string
param azureStorageSubscriptionId string
param azureStorageResourceGroupName string

param logAnalyticsWorkspaceId string

@description('Deploy the STANDARD tier BYO connections (Cosmos/Storage/Search) on the project. False = BASIC tier: project has no BYO connections (Microsoft-managed stores via the account capability host).')
param deployStandardAgent bool

// These BYO stores only exist in the STANDARD tier. In BASIC their names are empty, so we
// fall back to a placeholder to keep the (cross-scope) existing declarations valid — they are
// never dereferenced because the connections that use them are gated on deployStandardAgent.
resource searchService 'Microsoft.Search/searchServices@2024-06-01-preview' existing = {
  name: !empty(aiSearchName) ? aiSearchName : 'placeholder'
  scope: resourceGroup(aiSearchServiceSubscriptionId, aiSearchServiceResourceGroupName)
}
resource cosmosDBAccount 'Microsoft.DocumentDB/databaseAccounts@2024-12-01-preview' existing = {
  name: !empty(cosmosDBName) ? cosmosDBName : 'placeholder'
  scope: resourceGroup(cosmosDBSubscriptionId, cosmosDBResourceGroupName)
}
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: !empty(azureStorageName) ? azureStorageName : 'placeholder'
  scope: resourceGroup(azureStorageSubscriptionId, azureStorageResourceGroupName)
}

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
  scope: resourceGroup()
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: account
  name: projectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: projectDescription
    displayName: displayName
  }

  //throws an error if they already exist and are used by a capability host
  @onlyIfNotExists()
  resource project_connection_cosmosdb_account 'connections@2025-04-01-preview' = if (deployStandardAgent) {
    name: cosmosDBName
    properties: {
      category: 'CosmosDB'
      target: cosmosDBAccount.properties.documentEndpoint
      authType: 'AAD'
      metadata: {
        ApiType: 'Azure'
        ResourceId: cosmosDBAccount.id
        location: cosmosDBAccount.location
      }
    }
  }

  //throws an error if they already exist and are used by a capability host
  @onlyIfNotExists()
  resource project_connection_azure_storage 'connections@2025-04-01-preview' = if (deployStandardAgent) {
    name: azureStorageName
    properties: {
      category: 'AzureStorageAccount'
      target: storageAccount.properties.primaryEndpoints.blob
      authType: 'AAD'
      metadata: {
        ApiType: 'Azure'
        ResourceId: storageAccount.id
        location: storageAccount.location
      }
    }
  }

  //throws an error if they already exist and are used by a capability host
  @onlyIfNotExists()
  resource project_connection_azureai_search 'connections@2025-04-01-preview' = if (deployStandardAgent) {
    name: aiSearchName
    properties: {
      category: 'CognitiveSearch'
      target: 'https://${aiSearchName}.search.windows.net'
      authType: 'AAD'
      metadata: {
        ApiType: 'Azure'
        ResourceId: searchService.id
        location: searchService.location
      }
    }
  }
}

resource foundryDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: project
  name: 'diagnostics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output projectName string = project.name
output projectId string = project.id
output projectPrincipalId string = project.identity.principalId

#disable-next-line BCP053
output projectWorkspaceId string = project.properties.internalId

// The project's own AI Foundry API endpoint already contains the full project path,
// e.g. https://<account>.services.ai.azure.com/api/projects/<project>
#disable-next-line BCP053
output projectEndpoint string = project.properties.endpoints['AI Foundry API']

// Return the BYO connection names. Resource names already include the deployment's uniqueSuffix.
output cosmosDBConnection string = cosmosDBName
output azureStorageConnection string = azureStorageName
output aiSearchConnection string = aiSearchName
