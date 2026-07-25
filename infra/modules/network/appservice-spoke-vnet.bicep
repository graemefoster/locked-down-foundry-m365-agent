@description('Azure region for the deployment')
param location string

@description('The name of the App Service spoke virtual network')
param vnetName string = 'appservice-spoke-vnet'

@description('Address space for the App Service Spoke VNet')
param vnetAddressPrefix string = '10.1.0.0/16'

@description('Next hop IP address for the firewall (for UDR)')
param firewallPrivateIp string

@description('Custom DNS server IP (DNS Resolver inbound endpoint)')
param dnsServerIp string

@description('''
CIDR of the gateway spoke apim-subnet (APIM v2 outbound VNet integration). When non-empty,
the pe-subnet gets privateEndpointNetworkPolicies=Enabled + a UDR routing return traffic to
this CIDR back through the Azure Firewall — required for the MCP gateway path, where APIM
(in the gateway spoke) forwards to the MCP web app private endpoint (which lands in this
pe-subnet). Scoped to the apim-subnet CIDR only, so intra-VNet flows stay on system routes.
Empty = no route table / policy change.
''')
param apimSubnetCidr string = ''

var appServiceDelegatedSubnet = cidrSubnet(vnetAddressPrefix, 24, 0)
var peSubnet = cidrSubnet(vnetAddressPrefix, 24, 1)

resource routeTable 'Microsoft.Network/routeTables@2022-11-01' = {
  name: '${vnetName}-rt'
  location: location
  properties: {
    routes: [
      {
        name: 'InternetViaFirewall'
        properties: {
          nextHopType: 'VirtualAppliance'
          addressPrefix: '0.0.0.0/0'
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

// Return-path route table for the pe-subnet (MCP gateway path). When apimSubnetCidr
// is supplied, traffic from the MCP web app PE back to the APIM outbound subnet (in the
// gateway spoke) is force-tunnelled through the Azure Firewall so the flow is symmetric
// (APIM force-tunnels the forward path too). Scoped to the apim-subnet /24; all other
// pe-subnet traffic stays on system routes.
resource peRouteTable 'Microsoft.Network/routeTables@2022-11-01' = if (!empty(apimSubnetCidr)) {
  name: '${vnetName}-pe-rt'
  location: location
  properties: {
    routes: [
      {
        name: 'ApimReturnViaFirewall'
        properties: {
          nextHopType: 'VirtualAppliance'
          addressPrefix: apimSubnetCidr
          nextHopIpAddress: firewallPrivateIp
        }
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    dhcpOptions: {
      dnsServers: [
        dnsServerIp
      ]
    }
    subnets: [
      {
        name: 'AppServiceDelegated'
        properties: {
          addressPrefix: appServiceDelegatedSubnet
          delegations: [
            {
              name: 'AppServiceDelegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          routeTable: {
            id: routeTable.id
          }
        }
      }
      {
        name: 'pe-subnet'
        properties: {
          addressPrefix: peSubnet
          // MCP gateway path: honor the return-path UDR for PE traffic so APIM<->MCP PE
          // routing is symmetric through the firewall. No-op when apimSubnetCidr is empty.
          privateEndpointNetworkPolicies: empty(apimSubnetCidr) ? null : 'Enabled'
          routeTable: empty(apimSubnetCidr) ? null : { id: peRouteTable.id }
        }
      }
    ]
  }
}

output virtualNetworkName string = virtualNetwork.name
output virtualNetworkId string = virtualNetwork.id
output appServiceDelegatedSubnetId string = '${virtualNetwork.id}/subnets/AppServiceDelegated'
output peSubnetId string = '${virtualNetwork.id}/subnets/pe-subnet'
output peSubnetName string = 'pe-subnet'
