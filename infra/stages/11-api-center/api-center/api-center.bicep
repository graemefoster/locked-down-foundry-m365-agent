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

@description('Object (principal) ID of the deployment operator to grant "Azure API Center Data Reader" on the API Center (so whoever runs the deployment can read/search the synced inventory and export specs). Empty = skip the grant.')
param deployerPrincipalId string = ''

@description('Principal type of the deployment operator, used on its role assignment. Interactive azd runs are Users; CI runs are ServicePrincipals.')
@allowed([
  'User'
  'ServicePrincipal'
  'Group'
])
param deployerPrincipalType string = 'User'

// Built-in role: "API Management Service Reader Role" — the minimum role that lets the API
// Center managed identity read and import APIs from the APIM instance.
var apimServiceReaderRoleId = '71522526-b88f-4d52-b57f-d31fc3546d0d'

// Built-in role: "Azure API Center Data Reader" — read/search the API Center inventory and
// export API specifications (data-plane read). Granted to the deployment operator.
var apiCenterDataReaderRoleId = 'c7244dfb-f447-457d-b2ba-3999044d1706'

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource apiCenter 'Microsoft.ApiCenter/services@2024-06-01-preview' = {
  name: 'apic-${uniqueSuffix}'
  location: location
  sku: {name: 'Free'}
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

// Grant the deployment operator "Azure API Center Data Reader" so whoever runs the deployment
// can read/search the synced API inventory and export specs. Skipped when no principal id is
// supplied (e.g. a non-interactive run with no resolvable operator identity).
resource deployerDataReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  name: guid(apiCenter.id, deployerPrincipalId, apiCenterDataReaderRoleId)
  scope: apiCenter
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', apiCenterDataReaderRoleId)
    principalId: deployerPrincipalId
    principalType: deployerPrincipalType
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
