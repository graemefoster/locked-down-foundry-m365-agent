/*
Stage 11 — Azure API Center (orchestrator)

Publishes a discoverable inventory of the platform's APIs by standing up a free-plan Azure
API Center and wiring continuous synchronisation from the stage-10 APIM instance, so every
API — including the MCP servers fronted by APIM — surfaces in the catalog automatically.

  api-center/api-center.bicep → the API Center service + system-assigned identity, the APIM
                                "reader" role grant, the default workspace, and the APIM
                                apiSource (one-way continuous sync).

Runs AFTER stage 10 — the APIM instance must exist before it can be linked. The apimName is
threaded from stage 10's output so this stage is ordered after it.
*/

param location string
param uniqueSuffix string

@description('Name of the platform APIM instance (stage 10) whose APIs are synced into the API Center inventory.')
param apimName string

@description('Object (principal) ID of the deployment operator to grant "Azure API Center Data Reader" on the API Center. Empty = skip the grant.')
param deployerPrincipalId string = ''

@description('Principal type of the deployment operator, used on its role assignment.')
@allowed([
  'User'
  'ServicePrincipal'
  'Group'
])
param deployerPrincipalType string = 'User'

module apiCenter './api-center/api-center.bicep' = {
  name: 'api-center-${uniqueSuffix}'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    apimName: apimName
    deployerPrincipalId: deployerPrincipalId
    deployerPrincipalType: deployerPrincipalType
  }
}

output apiCenterName string = apiCenter.outputs.apiCenterName
output apiCenterId string = apiCenter.outputs.apiCenterId
