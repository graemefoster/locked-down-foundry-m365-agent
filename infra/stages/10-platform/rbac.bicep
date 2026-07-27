/*
Stage 10 slice — Data-plane RBAC + capability host.
The project-identity role assignments on Storage / App Insights / ACR / the
Foundry project / CosmosDB / AI Search, then the Agents capability host (created
only AFTER the Cosmos/Storage/Search data-plane roles + private endpoints), then
the post-caphost container-scope roles (Blob Data Owner, Cosmos data contributor).
*/

param uniqueSuffix string
param projectCapHost string

param azureStorageName string
param aiSearchName string
param cosmosDBName string
param acrName string
param appInsightsName string

// Foundry account identity (from foundry-account slice).
param accountName string
param accountPrincipalId string

// Project identity + connections (from project slice).
param projectName string
param projectPrincipalId string
param projectWorkspaceIdGuid string
param cosmosDBConnection string
param azureStorageConnection string
param aiSearchConnection string

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
  Assigns the project SMI the storage blob data contributor role on the storage account
*/
module storageAccountRoleAssignment '../../modules/rbac/azure-storage-account-role-assignment.bicep' = {
  name: 'storage-ra-${uniqueSuffix}-deployment'
  params: {
    azureStorageName: azureStorageName
    projectPrincipalId: projectPrincipalId
  }
  dependsOn: [
    storage
  ]
}

/*
  Assigns the project SMI Reader role on Application Insights.
  This supports running Evaluations on existing traces.
*/
module appInsightsRoleAssignment '../../modules/rbac/app-insights-role-assignment.bicep' = {
  name: 'appi-ra-${uniqueSuffix}-deployment'
  params: {
    appInsightsName: appInsightsName
    accountPrincipalId: accountPrincipalId
    projectPrincipalId: projectPrincipalId
  }
}

/*
  Assigns the project SMI Container Registry Repository Reader role on ACR.
*/
module acrRoleAssignment '../../modules/rbac/acr-role-assignment.bicep' = {
  name: 'acr-ra-${uniqueSuffix}-deployment'
  params: {
    acrName: acrName
    projectPrincipalId: projectPrincipalId
  }
}

/*
  Assigns Foundry User role to the project SMI on the Foundry project resource.
*/
module foundryProjectRoleAssignment '../../modules/rbac/foundry-project-role-assignment.bicep' = {
  name: 'foundry-project-ra-${uniqueSuffix}-deployment'
  params: {
    accountName: accountName
    projectName: projectName
    projectPrincipalId: projectPrincipalId
  }
}

// The Comos DB Operator role must be assigned before the caphost is created
module cosmosAccountRoleAssignments '../../modules/rbac/cosmosdb-account-role-assignment.bicep' = {
  name: 'cosmos-account-ra-${uniqueSuffix}-deployment'
  params: {
    cosmosDBName: cosmosDBName
    projectPrincipalId: projectPrincipalId
  }
  dependsOn: [
    cosmosDB
  ]
}

// This role can be assigned before or after the caphost is created
module aiSearchRoleAssignments '../../modules/rbac/ai-search-role-assignments.bicep' = {
  name: 'ai-search-ra-${uniqueSuffix}-deployment'
  params: {
    aiSearchName: aiSearchName
    projectPrincipalId: projectPrincipalId
  }
  dependsOn: [
    aiSearch
  ]
}

// This module creates the capability host for the project and account
module addProjectCapabilityHost '../../modules/foundry/add-project-capability-host.bicep' = {
  name: 'capabilityHost-configuration-${uniqueSuffix}-deployment'
  params: {
    accountName: accountName
    projectName: projectName
    cosmosDBConnection: cosmosDBConnection
    azureStorageConnection: azureStorageConnection
    aiSearchConnection: aiSearchConnection
    projectCapHost: projectCapHost
  }
  dependsOn: [
    aiSearch
    storage
    cosmosDB
    cosmosAccountRoleAssignments
    storageAccountRoleAssignment
    aiSearchRoleAssignments
  ]
}

// The Storage Blob Data Owner role must be assigned after the caphost is created
module storageContainersRoleAssignment '../../modules/rbac/blob-storage-container-role-assignments.bicep' = {
  name: 'storage-containers-ra-${uniqueSuffix}-deployment'
  params: {
    aiProjectPrincipalId: projectPrincipalId
    storageName: azureStorageName
    workspaceId: projectWorkspaceIdGuid
  }
  dependsOn: [
    addProjectCapabilityHost
  ]
}

// The Cosmos Built-In Data Contributor role must be assigned after the caphost is created
module cosmosContainerRoleAssignments '../../modules/rbac/cosmos-container-role-assignments.bicep' = {
  name: 'cosmos-container-ra-${uniqueSuffix}-deployment'
  params: {
    cosmosAccountName: cosmosDBName
    projectWorkspaceId: projectWorkspaceIdGuid
    projectPrincipalId: projectPrincipalId
  }
  dependsOn: [
    addProjectCapabilityHost
    storageContainersRoleAssignment
  ]
}
