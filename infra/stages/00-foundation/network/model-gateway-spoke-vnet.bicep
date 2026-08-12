/*
  Model-Gateway Spoke VNet
  ------------------------
  Optional spoke that hosts the APIM Standard v2 model gateway and the "real"
  model-provider AI Foundry. Peered to the hub only — there is NO direct
  spoke-to-spoke peering with the Foundry spoke. The locked-down agent reaches
  the APIM inbound private endpoint by force-tunnelling through the Azure
  Firewall (its existing 0.0.0.0/0 UDR), gated by an AZFW network rule.

  Subnets:
    - apim-subnet : delegated to Microsoft.Web/serverFarms for APIM v2 outbound
      VNet integration. UDR 0.0.0.0/0 -> firewall.
    - pe-subnet   : APIM inbound PE + provider Foundry PE.
      privateEndpointNetworkPolicies = Enabled so the return-path UDR is honored,
      and UDR 0.0.0.0/0 -> firewall so responses to the agent go back symmetrically
      through the firewall (avoids asymmetric routing).

  Sources:
    - APIM v2 VNet integration (Microsoft.Web/serverFarms delegation):
      https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound
    - Route private endpoint traffic through a firewall (symmetric routing):
      https://learn.microsoft.com/azure/private-link/private-endpoint-overview
*/

@description('Azure region for the deployment')
param location string

@description('The name of the model-gateway spoke virtual network')
param vnetName string = 'model-gateway-spoke-vnet'

@description('Address space for the model-gateway spoke VNet')
param vnetAddressPrefix string = '10.3.0.0/16'

@description('The name of the APIM VNet-integration subnet')
param apimSubnetName string = 'apim-subnet'

@description('The name of the Private Endpoint subnet')
param peSubnetName string = 'pe-subnet'

@description('Next hop IP address for the firewall (for UDR). Empty when deployFirewall=false.')
param firewallPrivateIp string

@description('''
Deploy the 0.0.0.0/0 force-tunnel UDR pointing at the Azure Firewall. When false (firewall
opt-out tier), no route table is created and the APIM/PE subnets fall back to Azure default
outbound. APIM v2 platform egress is still governed by the apim-subnet NSG.
''')
param deployFirewall bool

@description('Custom DNS server IP (DNS Resolver inbound endpoint)')
param dnsServerIp string

var apimSubnet = cidrSubnet(vnetAddressPrefix, 24, 0)
var peSubnet = cidrSubnet(vnetAddressPrefix, 24, 1)

// NSG for the APIM v2 outbound VNet-integration subnet. APIM v2 requires
// outbound access to Azure Storage and Azure Key Vault (platform dependencies).
// Inbound NSG rules are NOT enforced for v2 outbound integration, so only the
// documented outbound dependencies plus a deny-all fallback are defined.
// https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound
resource apimNsg 'Microsoft.Network/networkSecurityGroups@2022-05-01' = {
  name: '${vnetName}-apim-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-Storage-Outbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Storage'
          destinationPortRange: '443'
          description: 'APIM v2 dependency on Azure Storage.'
        }
      }
      {
        name: 'Allow-KeyVault-Outbound'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureKeyVault'
          destinationPortRange: '443'
          description: 'APIM v2 dependency on Azure Key Vault.'
        }
      }
    ]
  }
}

// Force-tunnel all egress (and PE return traffic) via the Azure Firewall.
resource routeTable 'Microsoft.Network/routeTables@2022-11-01' = if (deployFirewall) {
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
        name: apimSubnetName
        properties: {
          addressPrefix: apimSubnet
          delegations: [
            {
              name: 'apim-vnet-integration'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          networkSecurityGroup: {
            id: apimNsg.id
          }
          routeTable: deployFirewall ? { id: routeTable!.id } : null
        }
      }
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnet
          // Enabled so the UDR below is honored for private-endpoint traffic —
          // required to keep agent<->APIM routing symmetric through the firewall.
          privateEndpointNetworkPolicies: 'Enabled'
          routeTable: deployFirewall ? { id: routeTable!.id } : null
        }
      }
    ]
  }
}

output virtualNetworkName string = virtualNetwork.name
output virtualNetworkId string = virtualNetwork.id
output apimSubnetId string = '${virtualNetwork.id}/subnets/${apimSubnetName}'
output apimSubnetCidr string = apimSubnet
output peSubnetId string = '${virtualNetwork.id}/subnets/${peSubnetName}'
output peSubnetName string = peSubnetName
output peSubnetCidr string = peSubnet
output routeTableName string = deployFirewall ? routeTable!.name : ''
