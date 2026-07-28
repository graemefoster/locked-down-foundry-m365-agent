// Assigns Foundry User role to the project managed identity on the Foundry project

@description('Name of the AI Services account')
param accountName string

@description('Name of the Foundry project')
param projectName string

@description('Principal ID of the Foundry project managed identity')
param projectPrincipalId string

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
  scope: resourceGroup()
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: account
  name: projectName
}

// Foundry User: 53ca6127-db72-4b80-b1b0-d745d6d5456d
resource foundryUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '53ca6127-db72-4b80-b1b0-d745d6d5456d'
  scope: resourceGroup()
}

resource foundryUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: project
  name: guid(projectPrincipalId, foundryUserRole.id, project.id)
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: foundryUserRole.id
    principalType: 'ServicePrincipal'
  }
}

//Continuous evals for some reason needed Foundry User on the account.
//Waiting to get confirm if this is expected or if there's a bug in the permission model that needs to be fixed, but adding it here for now to unblock testing.
resource foundryUserRoleAssignmentOnAccount 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(projectPrincipalId, foundryUserRole.id, account.id)
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: foundryUserRole.id
    principalType: 'ServicePrincipal'
  }
}


