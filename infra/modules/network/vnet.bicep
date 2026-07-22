/*
Virtual Network Module
This module deploys the core network infrastructure with security controls:

1. Address Space:
   - VNet CIDR: 172.16.0.0/16 OR 192.168.0.0/16
   - Agents Subnet: 172.16.0.0/24 OR 192.168.0.0/24
   - Private Endpoint Subnet: 172.16.101.0/24 OR 192.168.1.0/24

2. Security Features:
   - Network isolation
   - Subnet delegation
   - Private endpoint subnet
*/

@description('Azure region for the deployment')
param location string

@description('The name of the virtual network')
param vnetName string = 'agents-vnet-test'

@description('The name of Agents Subnet')
param agentSubnetName string = 'agent-subnet'

@description('The name of Hub subnet')
param peSubnetName string = 'pe-subnet'

@description('Address space for the VNet')
param vnetAddressPrefix string = ''

@description('Address prefix for the agent subnet')
param agentSubnetPrefix string = ''

@description('Address prefix for the private endpoint subnet')
param peSubnetPrefix string = ''
var defaultVnetAddressPrefix = '192.168.0.0/16'
var vnetAddress = empty(vnetAddressPrefix) ? defaultVnetAddressPrefix : vnetAddressPrefix
var agentSubnet = empty(agentSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 0) : agentSubnetPrefix
var peSubnet = empty(peSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 1) : peSubnetPrefix
var firewallSubnet = cidrSubnet(vnetAddress, 24, 2)
var firewallMgmtSubnet = cidrSubnet(vnetAddress, 24, 3)
var appservicedelegatedSubnet = cidrSubnet(vnetAddress, 24, 4)
var vmSubnet = cidrSubnet(vnetAddress, 24, 5)


resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2022-05-01' = {
  name: 'allowvirtualmachines-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'default-allow-3389-from-bastion'
        properties: {
          priority: 999
          access: 'Allow'
          direction: 'Inbound'
          destinationPortRange: '3389'
          protocol: 'Tcp'
          sourceAddressPrefix: '168.63.129.16/32' //bastion host
          destinationAddressPrefix: '*'
          sourcePortRange: '*'
        }
      }
    ]
  }
}


resource routeTable 'Microsoft.Network/routeTables@2022-11-01' = {
  name: 'agent-subnet-firewall-rt'
  location: location
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddress
      ]
    }
    subnets: [
      {
        name: agentSubnetName
        properties: {
          addressPrefix: agentSubnet
          delegations: [
            {
              name: 'Microsoft.app/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          routeTable: {
            id: routeTable.id
          }
        }
      }
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnet
        }
      }
      {
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: firewallSubnet
        }
      }
      {
        name: 'AzureFirewallManagementSubnet'
        properties: {
          addressPrefix: firewallMgmtSubnet
        }
      }
      {
        name: 'AppServiceDelegated'
        properties: {
          addressPrefix: appservicedelegatedSubnet
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
        name: 'VirtualMachines'
        properties: {
          addressPrefix: vmSubnet
          routeTable: {
            id: routeTable.id
          }
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
          defaultOutboundAccess: false
        }
      }
    ]
  }
}
// Output variables
output peSubnetName string = peSubnetName
output agentSubnetName string = agentSubnetName
output agentSubnetId string = '${virtualNetwork.id}/subnets/${agentSubnetName}'
output peSubnetId string = '${virtualNetwork.id}/subnets/${peSubnetName}'
output virtualNetworkName string = virtualNetwork.name
output virtualNetworkId string = virtualNetwork.id
output virtualNetworkResourceGroup string = resourceGroup().name
output virtualNetworkSubscriptionId string = subscription().subscriptionId
output firewallSubnetId string = '${virtualNetwork.id}/subnets/AzureFirewallSubnet'
output firewallManagementSubnetId string = filter(
  virtualNetwork.properties.subnets,
  subnet => subnet.name == 'AzureFirewallManagementSubnet'
)[0].id
output firewallRouteTableName string = routeTable.name
output appServiceDelegatedSubnetId string = '${virtualNetwork.id}/subnets/AppServiceDelegated'
output vmSubnetName string = 'VirtualMachines'
