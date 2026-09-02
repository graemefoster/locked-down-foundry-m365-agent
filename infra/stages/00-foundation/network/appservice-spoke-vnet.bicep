@description('Azure region for the deployment')
param location string

@description('The name of the App Service spoke virtual network')
param vnetName string = 'appservice-spoke-vnet'

@description('App Service VNet and subnet CIDRs from the shared address plan.')
param addressPlan object

@description('Next hop IP address for the Azure Firewall (UDR next hop for spoke egress).')
param firewallPrivateIp string

@description('Custom DNS server IP (DNS Resolver inbound endpoint)')
param dnsServerIp string

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
        addressPlan.vnetAddressPrefix
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
          addressPrefix: addressPlan.delegatedSubnetCidr
          delegations: [
            {
              name: 'AppServiceDelegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          routeTable: { id: routeTable.id }
        }
      }
      {
        name: 'pe-subnet'
        properties: {
          addressPrefix: addressPlan.peSubnetCidr
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
