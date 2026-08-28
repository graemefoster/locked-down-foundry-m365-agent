/*
App Service Private Endpoint Module (App Service Spoke)
------------------------------------------------------
Dedicated leaf carved out of private-endpoint-and-dns.bicep. The caller passes
`[mcpWebAppName]` ONLY — the YARP proxy is the public ingress and is never PE'd.
*/

// App Service Spoke VNet (for App Service PEs)
@description('Name of the App Service spoke VNet')
param appServiceSpokeVnetName string
@description('Name of the PE subnet in App Service spoke')
param appServicePeSubnetName string

param appServiceWebAppNames string[]

// Private DNS zone id (created early in stage 00 and threaded in).
param appServiceDnsZoneId string

// Reference App Service Spoke VNet and PE subnet
resource appServiceSpokeVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: appServiceSpokeVnetName
}
resource appServicePeSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: appServiceSpokeVnet
  name: appServicePeSubnetName
}

/* -------------------------------------------- App Service PEs (in App Service Spoke) -------------------------------------------- */

resource appService 'Microsoft.Web/sites@2025-03-01' existing = [
  for appServiceWebAppName in appServiceWebAppNames: {
    name: appServiceWebAppName
  }
]

resource appServicePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = [
  for (appServiceWebAppName, i) in appServiceWebAppNames: {
    name: '${appServiceWebAppName}-private-endpoint'
    // TEMPORARY: keep the private endpoint colocated with the Australia East App Service spoke.
    location: 'australiaeast'
    properties: {
      subnet: { id: appServicePeSubnet.id }
      privateLinkServiceConnections: [
        {
          name: '${appServiceWebAppName}-private-link-service-connection'
          properties: {
            privateLinkServiceId: appService[i].id
            groupIds: ['sites']
          }
        }
      ]
    }
  }
]

resource appServiceDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [
  for (appServiceName, i) in appServiceWebAppNames: {
    name: '${appServiceName}-dns-group'
    parent: appServicePrivateEndpoint[i]
    properties: {
      privateDnsZoneConfigs: [
        { name: '${appServiceName}-dns-config', properties: { privateDnsZoneId: appServiceDnsZoneId } }
      ]
    }
  }
]
