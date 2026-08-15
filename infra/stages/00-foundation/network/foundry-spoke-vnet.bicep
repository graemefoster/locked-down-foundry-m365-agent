@description('Azure region for the deployment')
param location string

@description('The name of the Foundry spoke virtual network')
param vnetName string = 'foundry-spoke-vnet'

@description('Address space for the Foundry Spoke VNet')
param vnetAddressPrefix string = '10.2.0.0/16'

@description('The name of the Agents Subnet')
param agentSubnetName string = 'agent-subnet'

@description('The name of the Private Endpoint subnet')
param peSubnetName string = 'pe-subnet'

@description('Next hop IP address for the Azure Firewall (UDR next hop for spoke egress).')
param firewallPrivateIp string

@description('Custom DNS server IP (DNS Resolver inbound endpoint)')
param dnsServerIp string

@description('''
CIDRs permitted to make inbound calls to the agent ingress (the /invoke path):
typically the App Service / YARP spoke and the private-endpoint subnet. Used to
scope the agent-subnet NSG inbound rule to explicit callers on 443 only, instead
of allowing the entire VirtualNetwork. Least-privilege: add a CIDR here only when
a subnet legitimately needs to reach the agent front door.
''')
param agentInboundAllowedCidrs array

@description('''
CIDR of the model-gateway spoke private-endpoint subnet that hosts the APIM inbound
private endpoint. When non-empty, an outbound NSG rule is added so the agent subnet can
reach the APIM gateway PE on 443. Empty = model gateway not deployed, so no rule is added.
''')
param modelGatewayPeCidr string = ''

@description('''
CIDR of the App Service spoke private-endpoint subnet that hosts the MCP web app inbound
private endpoint. The agent subnet is allowed outbound to this on 443 so the hosted agent can
enumerate/call the MCP tool. Force-tunnelled via the firewall (0.0.0.0/0 UDR) but the NSG sees
the real PE IP, so this explicit allow is required.
''')
param appServicePeCidr string = ''

@description('''
CIDR of the gateway spoke apim-subnet (APIM v2 outbound VNet integration). When non-empty,
the Foundry pe-subnet gets privateEndpointNetworkPolicies=Enabled + a UDR routing return
traffic to this CIDR back through the Azure Firewall — required for the Teams inbound path,
where APIM (in the gateway spoke) forwards to the primary Foundry account private endpoint
(which lands in this pe-subnet). Scoped to the apim-subnet CIDR only, so intra-VNet flows
(agent <-> PEs, 10.2.x) stay on system routes. Empty = no route table / policy change.
''')
param apimSubnetCidr string = ''

var agentSubnet = cidrSubnet(vnetAddressPrefix, 24, 0)
var peSubnet = cidrSubnet(vnetAddressPrefix, 24, 1)
var vmSubnet = cidrSubnet(vnetAddressPrefix, 24, 2)
var deploymentScriptsSubnet = cidrSubnet(vnetAddressPrefix, 24, 3)
var bastionSubnet = cidrSubnet(vnetAddressPrefix, 26, 16)

// Azure DNS "wire server" virtual IP. ACA requires DNS to this IP and it must
// never be denied. See https://learn.microsoft.com/azure/container-apps/firewall-integration
var azureDnsVirtualIp = '168.63.129.16'

// Return-path route table for the pe-subnet (Teams inbound path only). When apimSubnetCidr
// is supplied, traffic from the Foundry account PE back to the APIM outbound subnet (in the
// gateway spoke) is force-tunnelled through the Azure Firewall so the flow is symmetric
// (APIM force-tunnels the forward path too). Scoped to the apim-subnet /24; all other
// pe-subnet traffic (including intra-VNet agent<->PE) stays on system routes.
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

// Minimal NSG for the ephemeral deployment-script containers: no inbound connections
// are ever needed; outbound enforcement is delegated to the Azure Firewall (this subnet
// is in the firewall's unrestricted source list so az CLI can reach AAD / ARM).
resource deploymentScriptsNsg 'Microsoft.Network/networkSecurityGroups@2022-05-01' = {
  name: '${vnetName}-scripts-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 100
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Deployment script containers are ephemeral — no inbound connections needed.'
        }
      }
    ]
  }
}

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2022-05-01' = {
  name: '${vnetName}-vm-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-Rdp-From-Bastion'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          destinationPortRange: '3389'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnet
          destinationAddressPrefix: vmSubnet
          sourcePortRange: '*'
          description: 'Allow Windows VM RDP only from the dedicated Azure Bastion subnet.'
        }
      }
      {
        name: 'Allow-Ssh-From-Bastion'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          destinationPortRange: '22'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnet
          destinationAddressPrefix: vmSubnet
          sourcePortRange: '*'
          description: 'Allow optional Linux VM SSH only from the dedicated Azure Bastion subnet.'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4000
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Deny all other inbound traffic to the VM subnet.'
        }
      }
    ]
  }
}

resource bastionNsg 'Microsoft.Network/networkSecurityGroups@2022-05-01' = {
  name: '${vnetName}-bastion-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-Https-Internet-Inbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: bastionSubnet
          destinationPortRange: '443'
          description: 'Azure Bastion browser/client ingress.'
        }
      }
      {
        name: 'Allow-GatewayManager-Inbound'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: bastionSubnet
          destinationPortRange: '443'
          description: 'Azure Bastion control-plane management.'
        }
      }
      {
        name: 'Allow-LoadBalancer-Inbound'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: bastionSubnet
          destinationPortRange: '443'
          description: 'Azure Bastion health probes.'
        }
      }
      {
        name: 'Allow-BastionHost-Inbound'
        properties: {
          priority: 130
          access: 'Allow'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: bastionSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: bastionSubnet
          destinationPortRanges: [
            '8080'
            '5701'
          ]
          description: 'Azure Bastion host-to-host communication.'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4000
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Deny all other inbound traffic to the Bastion subnet.'
        }
      }
      {
        name: 'Allow-SshRdp-Vnet-Outbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: vmSubnet
          destinationPortRanges: [
            '22'
            '3389'
          ]
          description: 'Azure Bastion sessions to VMs.'
        }
      }
      {
        name: 'Allow-AzureCloud-Outbound'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '443'
          description: 'Azure Bastion platform dependencies.'
        }
      }
      {
        name: 'Allow-Internet-Outbound'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '80'
          description: 'Azure Bastion certificate revocation checks.'
        }
      }
      {
        name: 'Allow-BastionHost-Outbound'
        properties: {
          priority: 130
          access: 'Allow'
          direction: 'Outbound'
          protocol: '*'
          sourceAddressPrefix: bastionSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: bastionSubnet
          destinationPortRanges: [
            '8080'
            '5701'
          ]
          description: 'Azure Bastion host-to-host communication.'
        }
      }
      {
        name: 'Deny-All-Outbound'
        properties: {
          priority: 4000
          access: 'Deny'
          direction: 'Outbound'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Deny all other outbound traffic from the Bastion subnet.'
        }
      }
    ]
  }
}

/*
  ==========================================================================
  Agent-subnet NSG — enterprise least-privilege, service-tag-only egress.
  ==========================================================================
  The agent subnet is an Azure Container Apps workload-profile environment
  (delegated to Microsoft.App/environments). Both inbound and outbound are
  deny-by-default; only the flows below are permitted. Design rules applied:

    * Egress uses service tags, never FQDNs or `*.` wildcards.
    * Private ("VirtualNetwork"-class) egress is NOT allowed broadly — it is
      split into explicit destinations: the agent subnet itself (data-plane),
      the PE subnet (443 only), the DNS resolver (/32, 53), and the firewall
      next hop (/32, 443). Nothing else in the VNet/peers is reachable.
    * Every internet-bound destination is a specific Azure service tag on 443.
    * Inbound is scoped to LB health probes, intra-subnet data-plane, and the
      explicit caller CIDRs (agentInboundAllowedCidrs) on 443 — not the whole
      VirtualNetwork.
    * 168.63.129.16 (Azure DNS wire server) is always allowed and never denied.

  Sources:
    - ACA VNet/NSG requirements:
      https://learn.microsoft.com/azure/container-apps/firewall-integration
    - Foundry required outbound rules (AzureActiveDirectory, AzureMachineLearning
      for the Evaluators Catalogue):
      https://learn.microsoft.com/azure/foundry/how-to/managed-virtual-network#required-outbound-rules
  ==========================================================================
*/
resource agentNsg 'Microsoft.Network/networkSecurityGroups@2022-05-01' = {
  name: '${vnetName}-agent-nsg'
  location: location
  properties: {
    securityRules: concat([
      // ---------------- Inbound ----------------
      {
        name: 'Allow-LoadBalancer-Probes-Inbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: agentSubnet
          destinationPortRange: '30000-32767'
          description: 'ACA workload profile: allow Azure Load Balancer to probe backend pools.'
        }
      }
      {
        name: 'Allow-IntraSubnet-Inbound'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: agentSubnet
          destinationPortRange: '*'
          description: 'ACA data-plane: intra-subnet communication between environment nodes/pods.'
        }
      }
      {
        name: 'Allow-Callers-Inbound'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourceAddressPrefixes: agentInboundAllowedCidrs
          sourcePortRange: '*'
          destinationAddressPrefix: agentSubnet
          destinationPortRange: '443'
          description: 'Allow the /invoke path (App Service spoke) to reach the agent ingress on 443. Scoped to explicit caller CIDRs, not the whole VNet.'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4000
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Deny-by-default: block all other inbound (including public internet and unexpected VNet sources).'
        }
      }
      // ---------------- Outbound ----------------
      {
        name: 'Allow-IntraSubnet-Outbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Outbound'
          protocol: '*'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: agentSubnet
          destinationPortRange: '*'
          description: 'ACA data-plane: intra-subnet communication between environment nodes/pods.'
        }
      }
      {
        name: 'Allow-PrivateEndpoints-Outbound'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: peSubnet
          destinationPortRange: '443'
          description: 'Reach private endpoints (AI account, Search, Storage, Cosmos, Key Vault, ACR) on HTTPS. Scoped to the PE subnet.'
        }
      }
      {
        name: 'Allow-DnsResolver-Udp-Outbound'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Udp'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: '${dnsServerIp}/32'
          destinationPortRange: '53'
          description: 'DNS (UDP) to the hub DNS Private Resolver inbound endpoint over peering. Single-host scoped.'
        }
      }
      {
        name: 'Allow-DnsResolver-Tcp-Outbound'
        properties: {
          priority: 121
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: '${dnsServerIp}/32'
          destinationPortRange: '53'
          description: 'DNS (TCP) to the hub DNS Private Resolver inbound endpoint over peering. Single-host scoped.'
        }
      }
      {
        name: 'Allow-AzureActiveDirectory-Outbound'
        properties: {
          priority: 140
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureActiveDirectory'
          destinationPortRange: '443'
          description: 'Managed-identity token acquisition + Entra ID login.'
        }
      }
      {
        name: 'Allow-MicrosoftContainerRegistry-Outbound'
        properties: {
          priority: 150
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: 'MicrosoftContainerRegistry'
          destinationPortRange: '443'
          description: 'Pull platform/system container images from Microsoft Artifact Registry.'
        }
      }
      {
        name: 'Allow-AzureFrontDoorFirstParty-Outbound'
        properties: {
          priority: 160
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureFrontDoor.FirstParty'
          destinationPortRange: '443'
          description: 'Required dependency of MicrosoftContainerRegistry (image/AKS binary delivery over Front Door).'
        }
      }
      {
        name: 'Allow-AzureMonitor-Outbound'
        properties: {
          priority: 170
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureMonitor'
          destinationPortRange: '443'
          description: 'Application Insights / Azure Monitor tracing and metrics ingestion.'
        }
      }
      {
        name: 'Allow-AzureMachineLearning-Outbound'
        properties: {
          priority: 180
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureMachineLearning'
          destinationPortRange: '443'
          description: 'Foundry evaluations (Evaluators Catalogue).'
        }
      }
      {
        name: 'Allow-Agent365Telemetry-Outbound'
        properties: {
          priority: 185
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureFrontDoor.Frontend'
          destinationPortRange: '443'
          // ⚠️ OVER-BROAD — TRACKED FOR PRODUCT FEEDBACK. Agent 365 (A365) observability
          // exports telemetry to agent365.svc.cloud.microsoft, which is a CNAME to
          // api.powerplatform.com -> Azure Front Door. The data-plane destination IP is a
          // SHARED AFD anycast frontend, so the ONLY covering service tag is
          // AzureFrontDoor.Frontend — which spans EVERY Azure Front Door endpoint on the
          // internet (a potential exfiltration path). There is no A365 / cloud.microsoft /
          // PowerPlatform-specific tag, and NSGs are L3/L4 so they cannot filter by FQDN/SNI.
          // We accept this at the NSG only because all egress is force-tunnelled (UDR
          // 0.0.0.0/0) through the Azure Firewall, where an SNI application rule can pin the
          // exact FQDN. See docs/NETWORKING.md "Known limitation: Agent 365 telemetry egress".
          description: 'A365 observability telemetry to agent365.svc.cloud.microsoft (AFD anycast). tighten at firewall via SNI. See docs/NETWORKING.md.'
        }
      }
      {
        name: 'Allow-AzureDNS-Udp-Outbound'
        properties: {
          priority: 190
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Udp'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: azureDnsVirtualIp
          destinationPortRange: '53'
          description: 'Azure DNS wire server (UDP). Required by ACA and must never be denied.'
        }
      }
      {
        name: 'Allow-AzureDNS-Tcp-Outbound'
        properties: {
          priority: 191
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: azureDnsVirtualIp
          destinationPortRange: '53'
          description: 'Azure DNS wire server (TCP). Required by ACA and must never be denied.'
        }
      }
      {
        name: 'Deny-All-Outbound'
        properties: {
          priority: 4000
          access: 'Deny'
          direction: 'Outbound'
          protocol: '*'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Deny-by-default: everything not explicitly allowed above is blocked.'
        }
      }
    ], modelGatewayPeCidr == '' ? [] : [
      {
        name: 'Allow-ModelGatewayApim-Outbound'
        properties: {
          priority: 115
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: modelGatewayPeCidr
          destinationPortRange: '443'
          description: 'HTTPS to APIM model-gateway PE subnet. Force-tunnelled via firewall (UDR) but NSG sees the real PE IP, so this explicit allow is required.'
        }
      }
    ], appServicePeCidr == '' ? [] : [
      {
        name: 'Allow-AppServicePe-Outbound'
        properties: {
          priority: 116
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: appServicePeCidr
          destinationPortRange: '443'
          description: 'HTTPS to App Service spoke PE subnet (MCP web app). Force-tunnelled via firewall (UDR) but NSG sees the real PE IP, so allow required.'
        }
      }
    ], [
      {
        name: 'Allow-Firewall-Outbound'
        properties: {
          priority: 130
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourceAddressPrefix: agentSubnet
          sourcePortRange: '*'
          destinationAddressPrefix: '${firewallPrivateIp}/32'
          destinationPortRange: '443'
          description: 'Azure Firewall private IP — the UDR next hop for internet-bound (0.0.0.0/0) egress, HTTPS only. Single-host scoped.'
        }
      }
    ])
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
          routeTable: { id: routeTable.id }
          networkSecurityGroup: {
            id: agentNsg.id
          }
        }
      }
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnet
          // Teams inbound path: honor the return-path UDR for PE traffic so APIM<->Foundry PE
          // routing is symmetric through the firewall. No-op when apimSubnetCidr is empty.
          privateEndpointNetworkPolicies: empty(apimSubnetCidr) ? null : 'Enabled'
          routeTable: !empty(apimSubnetCidr) ? { id: peRouteTable!.id } : null
        }
      }
      {
        name: 'VirtualMachines'
        properties: {
          addressPrefix: vmSubnet
          routeTable: { id: routeTable.id }
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnet
          networkSecurityGroup: {
            id: bastionNsg.id
          }
        }
      }
      {
        // Dedicated subnet for Azure Deployment Script containers (seeding agents at
        // deploy time). Must be delegated to Microsoft.ContainerInstance/containerGroups
        // and must NOT share a subnet with private endpoints.
        name: 'DeploymentScripts'
        properties: {
          addressPrefix: deploymentScriptsSubnet
          delegations: [
            {
              name: 'Microsoft.ContainerInstance.containerGroups'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
          routeTable: { id: routeTable.id }
          networkSecurityGroup: {
            id: deploymentScriptsNsg.id
          }
        }
      }
    ]
  }
}

output virtualNetworkName string = virtualNetwork.name
output virtualNetworkId string = virtualNetwork.id
output agentSubnetId string = '${virtualNetwork.id}/subnets/${agentSubnetName}'
output peSubnetId string = '${virtualNetwork.id}/subnets/${peSubnetName}'
output vmSubnetName string = 'VirtualMachines'
output agentSubnetName string = agentSubnetName
output peSubnetName string = peSubnetName
output routeTableName string = routeTable.name
output deploymentScriptsSubnetId string = '${virtualNetwork.id}/subnets/DeploymentScripts'
