/*
Stage 10 slice — AI project.
The project (sub-resource of the Foundry account), its system-assigned identity,
the connections to Storage / CosmosDB / AI Search and the governed MCP server
connections, plus the workspace-id GUID reformatting used by the container-scope
data-plane RBAC in the rbac slice.
*/

param location string
param uniqueSuffix string

param projectName string
param projectDescription string
param displayName string

// Foundry account + dependent-resource identity/location (from earlier slices).
param accountName string
param aiSearchName string
param aiSearchServiceResourceGroupName string
param aiSearchServiceSubscriptionId string
param cosmosDBName string
param cosmosDBSubscriptionId string
param cosmosDBResourceGroupName string
param azureStorageName string
param azureStorageSubscriptionId string
param azureStorageResourceGroupName string

// From stage 00.
param logAnalyticsId string

// Governed MCP server connections (built in the model-gateway slice).
param mcpConnections array

// Existing data-plane resources (declared for the dependsOn ordering preserved from main).
resource storage 'Microsoft.Storage/storageAccounts@2022-05-01' existing = {
  name: azureStorageName
}

resource aiSearch 'Microsoft.Search/searchServices@2023-11-01' existing = {
  name: aiSearchName
}

resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: cosmosDBName
}

/*
  Creates a new project (sub-resource of the AI Services account)
*/
module aiProject '../../modules/foundry/ai-project-identity.bicep' = {
  name: 'ai-${projectName}-${uniqueSuffix}-deployment'
  params: {
    // workspace organization
    projectName: projectName
    projectDescription: projectDescription
    displayName: displayName
    location: location

    aiSearchName: aiSearchName
    aiSearchServiceResourceGroupName: aiSearchServiceResourceGroupName
    aiSearchServiceSubscriptionId: aiSearchServiceSubscriptionId

    cosmosDBName: cosmosDBName
    cosmosDBSubscriptionId: cosmosDBSubscriptionId
    cosmosDBResourceGroupName: cosmosDBResourceGroupName

    azureStorageName: azureStorageName
    azureStorageSubscriptionId: azureStorageSubscriptionId
    azureStorageResourceGroupName: azureStorageResourceGroupName
    // dependent resources
    accountName: accountName

    logAnalyticsWorkspaceId: logAnalyticsId

    // One project connection per governed MCP server, built from the APIM server outputs below.
    // The agent's tool token is minted for our own app registration audience (an audience we
    // control), so App Service built-in auth on the MCP web app accepts it. Shared audience for
    // now; per-server audiences would flow through this same array.
    mcpConnections: mcpConnections

  }
  dependsOn: [
    cosmosDB
    aiSearch
    storage
  ]
}

module formatProjectWorkspaceId '../../modules/foundry/format-project-workspace-id.bicep' = {
  name: 'format-project-workspace-id-${uniqueSuffix}-deployment'
  params: {
    projectWorkspaceId: aiProject.outputs.projectWorkspaceId
  }
}

output projectName string = aiProject.outputs.projectName
output projectId string = aiProject.outputs.projectId
output projectPrincipalId string = aiProject.outputs.projectPrincipalId
output projectEndpoint string = aiProject.outputs.projectEndpoint
output cosmosDBConnection string = aiProject.outputs.cosmosDBConnection
output azureStorageConnection string = aiProject.outputs.azureStorageConnection
output aiSearchConnection string = aiProject.outputs.aiSearchConnection
output projectWorkspaceIdGuid string = formatProjectWorkspaceId.outputs.projectWorkspaceIdGuid
