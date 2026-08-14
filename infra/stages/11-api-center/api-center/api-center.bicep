/*
Stage 11 — Azure API Center (module)

Stands up a free-plan Azure API Center and continuously synchronises the APIs published on
the platform APIM instance (stage 10) into its inventory.

  Microsoft.ApiCenter/services              → the API Center + system-assigned identity.
  Microsoft.Authorization/roleAssignments   → the API Center MI granted "API Management
                                              Service Reader Role" on the APIM so it can
                                              read/import APIs.
  services/workspaces (default)             → the single supported workspace.
  workspaces/apiSources                     → the APIM integration: one-way continuous sync
                                              of the APIM APIs (incl. MCP servers) into the
                                              inventory.

Note: Microsoft.ApiCenter/services has NO SKU/plan property — the Free plan is the ARM
default (the Standard plan only begins billing when linked to certain APIM tiers), so there
is nothing to set for "free".
*/

@description('Location for the API Center. API Center is available in a subset of Azure regions; australiaeast is supported.')
param location string

@description('Unique suffix shared across the deployment.')
param uniqueSuffix string

@description('Name of the platform APIM instance (stage 10) whose APIs are synced into the inventory.')
param apimName string

@description('Whether API definitions (specs) are imported alongside API metadata during sync.')
@allowed([
  'always'
  'never'
  'ondemand'
])
param importSpecification string = 'ondemand'

// Built-in role: "API Management Service Reader Role" — the minimum role that lets the API
// Center managed identity read and import APIs from the APIM instance.
var apimServiceReaderRoleId = '71522526-b88f-4d52-b57f-d31fc3546d0d'

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource apiCenter 'Microsoft.ApiCenter/services@2024-06-01-preview' = {
  name: 'apic-${uniqueSuffix}'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
}

// Grant the API Center's system-assigned identity read access to APIM so it can sync APIs.
resource apimReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(apim.id, apiCenter.id, apimServiceReaderRoleId)
  scope: apim
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', apimServiceReaderRoleId)
    principalId: apiCenter.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// The single supported workspace ('default' is the only allowed name today).
resource workspace 'Microsoft.ApiCenter/services/workspaces@2024-06-01-preview' = {
  parent: apiCenter
  name: 'default'
  properties: {
    title: 'Default workspace'
  }
}

// Continuous one-way sync of the APIM APIs (including MCP servers) into the inventory. Uses
// the API Center system-assigned identity (msiResourceId omitted). Depends on the role
// assignment so the identity can already read APIM at the first synchronisation.
resource apimSource 'Microsoft.ApiCenter/services/workspaces/apiSources@2024-06-01-preview' = {
  parent: workspace
  name: 'apim-${uniqueSuffix}'
  properties: {
    azureApiManagementSource: {
      resourceId: apim.id
    }
    importSpecification: importSpecification
  }
  dependsOn: [
    apimReaderAssignment
  ]
}

output apiCenterName string = apiCenter.name
output apiCenterId string = apiCenter.id
output apiCenterPrincipalId string = apiCenter.identity.principalId
