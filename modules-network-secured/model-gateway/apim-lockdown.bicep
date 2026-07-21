/*
  Model-Gateway: APIM public-access lockdown (phase 2)
  ----------------------------------------------------
  APIM cannot be CREATED with publicNetworkAccess = 'Disabled' — the control plane
  rejects it with ActivateServiceWithPrivateEndpointAccessNotAllowed. So apim.bicep
  creates the service with public access 'Enabled', the inbound private endpoint is
  created, and THEN this module re-applies the service resource with
  publicNetworkAccess = 'Disabled'.

  This is a property update (PATCH), not a recreate: the SKU, identity and VNet
  configuration are re-stated identically so nothing else drifts. It runs as its own
  nested deployment (a module) ordered AFTER the private endpoint via dependsOn in
  main.bicep. Disabling public access affects only the GATEWAY data plane — ARM can
  still manage the service, so this update succeeds.

  NOTE: this module declares ONLY the service resource (no child APIs/policies/
  subscriptions/loggers) so it does not race the child resources created by apim.bicep.
*/

@description('Name of the APIM instance to lock down')
param apimName string

@description('Azure region — must match the APIM/VNet region')
param location string

@description('Publisher email (must match apim.bicep to avoid drift)')
param publisherEmail string = 'noreply@microsoft.com'

@description('Publisher name (must match apim.bicep to avoid drift)')
param publisherName string = 'Model Gateway'

@description('Capacity (scale units) for the Standard v2 SKU (must match apim.bicep)')
param skuCapacity int = 1

@description('Resource ID of the delegated subnet used for outbound VNet integration (must match apim.bicep)')
param apimOutboundSubnetId string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  sku: {
    name: 'StandardV2'
    capacity: skuCapacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'External'
    virtualNetworkConfiguration: {
      subnetResourceId: apimOutboundSubnetId
    }
    // Phase 2: now that the inbound private endpoint exists, block public ingress.
    publicNetworkAccess: 'Disabled'
  }
}

output apimName string = apim.name
