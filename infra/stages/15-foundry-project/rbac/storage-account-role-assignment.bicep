// Grants the project managed identity Storage Blob Data Contributor at the STORAGE ACCOUNT
// scope. This is the broad grant needed BEFORE the Agents capability host is created; the
// narrower, condition-scoped Blob Data Owner grant on the agent containers is applied AFTER
// the capability host (see storage-container-role-assignment.bicep).

param azureStorageName string
param projectPrincipalId string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: azureStorageName
  scope: resourceGroup()
}

// Storage Blob Data Contributor: ba92f5b4-2d11-453d-a403-e96b0029c9fe
resource storageBlobDataContributor 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' existing = {
  name: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  scope: resourceGroup()
}

resource storageBlobDataContributorRoleAssignmentProject 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(projectPrincipalId, storageBlobDataContributor.id, storageAccount.id)
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: storageBlobDataContributor.id
    principalType: 'ServicePrincipal'
  }
}
