// Grants the project managed identity read access to the Azure Container Registry: Container
// Registry Repository Reader (pull image manifests/layers) plus Reader (registry metadata).
// Foundry pulls the agent runtime / custom tool images from here.

@description('Azure Container Registry resource name')
param acrName string

@description('Principal ID of the AI project managed identity')
param projectPrincipalId string

// Container Registry Repository Reader: b93aa761-3e63-49ed-ac28-beffa264f7ac
resource acrRepositoryReaderRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'b93aa761-3e63-49ed-ac28-beffa264f7ac'
  scope: resourceGroup()
}

resource acr 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  name: acrName
}

resource acrRepositoryReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: acr
  name: guid(projectPrincipalId, acrRepositoryReaderRole.id, acr.id)
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: acrRepositoryReaderRole.id
    principalType: 'ServicePrincipal'
  }
}

// Reader: acdd72a7-3385-48ef-bd42-f606fba81ae7
resource readerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  scope: resourceGroup()
}

resource acrReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: acr
  name: guid(projectPrincipalId, readerRole.id, acr.id)
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: readerRole.id
    principalType: 'ServicePrincipal'
  }
}

//
