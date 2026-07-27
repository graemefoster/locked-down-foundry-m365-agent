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

@description('MCP project connections to create — one per governed MCP server (from mcp/mcp.json). Each item is { name, url, audience }: name = the Foundry connection name; url = the APIM gateway URL the agent calls (trailing slash included); audience = the AgenticIdentityToken audience (an Entra app registration you control, not a Microsoft one). The array is authored in main.bicep from the APIM server outputs, so adding a server here needs no module change.')
param mcpConnections array

param logAnalyticsWorkspaceId string

resource searchService 'Microsoft.Search/searchServices@2024-06-01-preview' existing = {
  name: aiSearchName
  scope: resourceGroup(aiSearchServiceSubscriptionId, aiSearchServiceResourceGroupName)
}
resource cosmosDBAccount 'Microsoft.DocumentDB/databaseAccounts@2024-12-01-preview' existing = {
  name: cosmosDBName
  scope: resourceGroup(cosmosDBSubscriptionId, cosmosDBResourceGroupName)
}
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: azureStorageName
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
  resource project_connection_cosmosdb_account 'connections@2025-04-01-preview' = {
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
  resource project_connection_azure_storage 'connections@2025-04-01-preview' = {
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
  resource project_connection_azureai_search 'connections@2025-04-01-preview' = {
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

  //Not used by a capability host so does not need the @onlyIfNotExists() decorator
  //Sample MCP server
  // One project connection per governed MCP server (from mcp/mcp.json, via main.bicep). Each
  // agent reaches its MCP tools through the APIM gateway using this connection's AgenticIdentity
  // token, minted for that server's audience. Looping here (rather than a single scalar connection)
  // means there is no "primary" server to special-case — every server is wired symmetrically.
  resource project_connection_mcp_server 'connections@2026-03-01' = [for c in mcpConnections: {
    name: c.name
    properties: {
      category: 'RemoteTool'
      target: c.url
      authType: 'AgenticIdentityToken'
      audience: c.audience
      group: 'GenericProtocol'
      metadata: {
        type: 'custom_MCP'
      }
    }
  }]
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

// return the BYO connection names
output cosmosDBConnection string = cosmosDBName
output azureStorageConnection string = azureStorageName
output aiSearchConnection string = aiSearchName
