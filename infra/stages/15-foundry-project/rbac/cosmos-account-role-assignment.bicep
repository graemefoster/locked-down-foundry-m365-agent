// Grants the project managed identity Cosmos DB Operator at the Cosmos ACCOUNT scope. This
// control-plane role is required BEFORE the Agents capability host is created (the host wires
// the project to the Cosmos-backed thread store). The data-plane, container-scoped grant is
// applied after the host (see cosmos-container-role-assignment.bicep).
@description('Name of the Cosmos DB account')
param cosmosDBName string

@description('Principal ID of the AI project')
param projectPrincipalId string


resource cosmosDBAccount 'Microsoft.DocumentDB/databaseAccounts@2024-12-01-preview' existing = {
  name: cosmosDBName
  scope: resourceGroup()
}

resource cosmosDBOperatorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '230815da-be43-4aae-9cb4-875f7bd000aa'
  scope: resourceGroup()
}

resource cosmosDBOperatorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: cosmosDBAccount
  name: guid(projectPrincipalId, cosmosDBOperatorRole.id, cosmosDBAccount.id)
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: cosmosDBOperatorRole.id
    principalType: 'ServicePrincipal'
  }
}
