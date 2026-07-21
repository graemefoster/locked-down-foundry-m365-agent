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
