/*
Stage 15 — Foundry project (orchestrator)

The AI project (sub-resource of the Foundry account) and EVERYTHING that makes it
work end-to-end, co-located so the project's trust model reads as one unit:

  foundry/foundry-project.bicep             → the project + SMI + BYO connections
                                              (Storage / CosmosDB / AI Search)
  foundry/format-project-workspace-id.bicep → workspace-id GUID for container-scope RBAC
  rbac/*.bicep                              → the project-identity data-plane role
                                              assignments (Storage / App Insights / ACR /
                                              Foundry project / CosmosDB / AI Search) +
                                              the project Key Vault Crypto User (CMK) grant
  foundry/add-project-capability-host.bicep → the Agents capability host (created only
                                              AFTER the Cosmos/Storage/Search data-plane
                                              roles + private endpoints), then the
                                              post-caphost container-scope roles

Runs AFTER stage 13 (needs the account) and stage 10 (needs the data substrate +
private endpoints). The two hard sequencing rules survive as intra-stage ordering:
data-plane-RBAC-before-capability-host, and container-scope-roles-after-capability-host.
*/

param location string
param uniqueSuffix string

param projectName string
param projectDescription string
param displayName string
param projectCapHost string

@description('Deploy the STANDARD agent tier: BYO connections + project capability host + BYO data-plane RBAC. False = BASIC tier: project only (agents run on the account capability host + Microsoft-managed stores).')
param deployStandardAgent bool

// Foundry account (from stage 13).
param accountName string

// Dependent-resource identity/location (from stage 10 data resources).
param aiSearchName string
param aiSearchServiceResourceGroupName string
param aiSearchServiceSubscriptionId string
param cosmosDBName string
param cosmosDBSubscriptionId string
param cosmosDBResourceGroupName string
param azureStorageName string
param azureStorageSubscriptionId string
param azureStorageResourceGroupName string
param acrName string
param appInsightsName string
param keyVaultName string

// From stage 00.
param logAnalyticsId string

@description('Object ID of the deploying/publishing user (azd AZURE_PRINCIPAL_ID). Passed to the Foundry User grant so the delegated M365 publish token can perform agents/write.')
param deployerPrincipalId string = ''

@description('Principal type of deployerPrincipalId.')
param deployerPrincipalType string = 'User'

// Existing data-plane resources (declared for the dependsOn ordering preserved from stage 10).
// Only referenced by STANDARD-tier modules; fall back to a placeholder name in BASIC so the
// declarations stay valid when the trio names are empty.
resource storage 'Microsoft.Storage/storageAccounts@2022-05-01' existing = {
  name: !empty(azureStorageName) ? azureStorageName : 'placeholder'
}

resource aiSearch 'Microsoft.Search/searchServices@2023-11-01' existing = {
  name: !empty(aiSearchName) ? aiSearchName : 'placeholder'
}

resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: !empty(cosmosDBName) ? cosmosDBName : 'placeholder'
}

/*
  Creates a new project (sub-resource of the AI Services account) + BYO connections.
*/
module aiProject './foundry/foundry-project.bicep' = {
  name: 'ai-${projectName}-${uniqueSuffix}-deployment'
  params: {
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

    accountName: accountName

    logAnalyticsWorkspaceId: logAnalyticsId
    deployStandardAgent: deployStandardAgent
  }
  dependsOn: []
}

module formatProjectWorkspaceId './foundry/format-project-workspace-id.bicep' = if (deployStandardAgent) {
  name: 'format-project-workspace-id-${uniqueSuffix}-deployment'
  params: {
    projectWorkspaceId: aiProject.outputs.projectWorkspaceId
  }
}

// ==================== Project data-plane RBAC ====================

/*
  Assigns the project SMI the storage blob data contributor role on the storage account
*/
module storageAccountRoleAssignment './rbac/storage-account-role-assignment.bicep' = if (deployStandardAgent) {
  name: 'storage-ra-${uniqueSuffix}-deployment'
  params: {
    azureStorageName: azureStorageName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    storage
  ]
}

/*
  Assigns the project SMI Reader role on Application Insights (for continuous evaluations).
*/
module appInsightsProjectRoleAssignment './rbac/app-insights-project-role-assignment.bicep' = {
  name: 'appi-project-ra-${uniqueSuffix}-deployment'
  params: {
    appInsightsName: appInsightsName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
}

/*
  Assigns the project SMI Container Registry Repository Reader role on ACR.
*/
module acrRoleAssignment './rbac/acr-role-assignment.bicep' = {
  name: 'acr-ra-${uniqueSuffix}-deployment'
  params: {
    acrName: acrName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
}

/*
  Assigns Foundry User role to the project SMI on the Foundry project resource.
*/
module foundryProjectRoleAssignment './rbac/foundry-project-role-assignment.bicep' = {
  name: 'foundry-project-ra-${uniqueSuffix}-deployment'
  params: {
    accountName: accountName
    projectName: aiProject.outputs.projectName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
    deployerPrincipalId: deployerPrincipalId
    deployerPrincipalType: deployerPrincipalType
  }
}

// The Cosmos DB Operator role must be assigned before the caphost is created
module cosmosAccountRoleAssignments './rbac/cosmos-account-role-assignment.bicep' = if (deployStandardAgent) {
  name: 'cosmos-account-ra-${uniqueSuffix}-deployment'
  params: {
    cosmosDBName: cosmosDBName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    cosmosDB
  ]
}

// This role can be assigned before or after the caphost is created
module aiSearchRoleAssignments './rbac/ai-search-role-assignment.bicep' = if (deployStandardAgent) {
  name: 'ai-search-ra-${uniqueSuffix}-deployment'
  params: {
    aiSearchName: aiSearchName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    aiSearch
  ]
}

// Grant the project SMI Key Vault Crypto User (CMK) — no re-PUT here; the project
// participates in the account/storage CMK trust, so only the role is needed.
module keyVaultProjectRoleAssignment './rbac/keyvault-project-role-assignment.bicep' = {
  name: 'keyvault-project-rbac-${uniqueSuffix}-deployment'
  params: {
    keyVaultName: keyVaultName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
}

// ==================== Capability host + post-caphost container-scope RBAC ====================

// This module creates the capability host for the project and account
module addProjectCapabilityHost './foundry/add-project-capability-host.bicep' = if (deployStandardAgent) {
  name: 'capabilityHost-configuration-${uniqueSuffix}-deployment'
  params: {
    accountName: accountName
    projectName: aiProject.outputs.projectName
    cosmosDBConnection: aiProject.outputs.cosmosDBConnection
    azureStorageConnection: aiProject.outputs.azureStorageConnection
    aiSearchConnection: aiProject.outputs.aiSearchConnection
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
module storageContainersRoleAssignment './rbac/storage-container-role-assignment.bicep' = if (deployStandardAgent) {
  name: 'storage-containers-ra-${uniqueSuffix}-deployment'
  params: {
    aiProjectPrincipalId: aiProject.outputs.projectPrincipalId
    storageName: azureStorageName
    workspaceId: formatProjectWorkspaceId!.outputs.projectWorkspaceIdGuid
  }
  dependsOn: [
    addProjectCapabilityHost
  ]
}

// The Cosmos Built-In Data Contributor role must be assigned after the caphost is created
module cosmosContainerRoleAssignments './rbac/cosmos-container-role-assignment.bicep' = if (deployStandardAgent) {
  name: 'cosmos-container-ra-${uniqueSuffix}-deployment'
  params: {
    cosmosAccountName: cosmosDBName
    projectWorkspaceId: formatProjectWorkspaceId!.outputs.projectWorkspaceIdGuid
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    addProjectCapabilityHost
    storageContainersRoleAssignment
  ]
}

output projectName string = aiProject.outputs.projectName
output projectId string = aiProject.outputs.projectId
output projectEndpoint string = aiProject.outputs.projectEndpoint
