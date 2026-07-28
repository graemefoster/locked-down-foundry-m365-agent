// Grants the project managed identity the Cosmos DB built-in Data Contributor role
// (00000000-...-002), data-plane scoped to the '<workspaceId>-thread-message-store' container
// that the Agents capability host provisions in the 'enterprise_memory' database. Applied
// AFTER the capability host, because the container doesn't exist until the host creates it.

@description('Name of the Cosmos DB account')
param cosmosAccountName string

@description('Principal ID of the AI project managed identity')
param projectPrincipalId string

param projectWorkspaceId string

var userThreadName = '${projectWorkspaceId}-thread-message-store'

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-12-01-preview' existing = {
  name: cosmosAccountName
  scope: resourceGroup()
}

// Reference existing database
resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-12-01-preview' existing = {
  parent: cosmosAccount
  name: 'enterprise_memory'
}

resource containerUserMessageStore  'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-12-01-preview' existing = {
  parent: database
  name: userThreadName
}

var roleDefinitionId = resourceId(
  'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions', 
  cosmosAccountName, 
  '00000000-0000-0000-0000-000000000002'
)

var accountScope = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${cosmosAccountName}/dbs/enterprise_memory'

resource containerRoleAssignmentUserContainer 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2022-05-15' = {
  parent: cosmosAccount
  name: guid(projectWorkspaceId, containerUserMessageStore.id, roleDefinitionId, projectPrincipalId)
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: roleDefinitionId
    scope: accountScope
  }
}


  