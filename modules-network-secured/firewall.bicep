param firewallPipName string
param firewallMgmtPipName string
param firewallName string
param firewallPolicyName string
param location string = resourceGroup().location
param firewallSubnetId string
param firewallManagementSubnetId string
param logAnalyticsId string
param yarpProxyFqdn string

@description('Agent subnet CIDR. Egress from this subnet is locked down to an explicit service-tag allow-list on 443.')
param agentSubnetCidr string

@description('''
Source CIDRs that remain UNRESTRICTED at the firewall (dev VM subnet + App Service
spoke). Per the design, only the agent subnet is locked down; the dev VM and the
App Service spoke keep general outbound so day-to-day work is unaffected.
''')
param unrestrictedSourceCidrs array

@description('Enable the optional model-gateway firewall rules (agent -> APIM inbound PE, and APIM subnet platform egress).')
param enableModelGateway bool = false

@description('CIDR of the gateway spoke pe-subnet (APIM inbound PE). The agent subnet is allowed to reach this on 443.')
param modelGatewayPeSubnetCidr string = ''

@description('CIDR of the gateway spoke apim-subnet (APIM v2 outbound VNet integration). Allowed platform egress on 443.')
param modelGatewayApimSubnetCidr string = ''

// Service tags APIM v2 may reach for platform dependencies / MI token acquisition
// when its outbound-integration subnet force-tunnels 0.0.0.0/0 through the firewall.
// Scoped to 443; anything else falls through to the implicit deny.
var apimEgressServiceTags = [
  'AzureActiveDirectory'
  'AzureMonitor'
  'Storage'
  'AzureKeyVault'
]

// Service tags the agent subnet is permitted to reach on 443 (network rules). No FQDNs, no wildcards.
var agentEgressServiceTags = [
  'AzureActiveDirectory'
  'MicrosoftContainerRegistry'
  'AzureFrontDoor.FirstParty'
  'AzureMonitor'
  'AzureMachineLearning'
]

resource firewallPip 'Microsoft.Network/publicIPAddresses@2022-11-01' = {
  name: firewallPipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
  zones: pickZones('Microsoft.Network', 'publicIPAddresses', location, 3)
}

resource firewallManagementPip 'Microsoft.Network/publicIPAddresses@2022-11-01' = {
  name: firewallMgmtPipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
  zones: pickZones('Microsoft.Network', 'publicIPAddresses', location, 3)
}

resource fwallPolicy 'Microsoft.Network/firewallPolicies@2022-11-01' = {
  name: firewallPolicyName
  location: location
  properties: {
    sku: {
      tier: 'Basic'
    }
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2022-11-01' = {
  name: firewallName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: firewallSubnetId
          }
          publicIPAddress: {
            id: firewallPip.id
          }
        }
      }
    ]
    sku: {
      name: 'AZFW_VNet'
      tier: 'Basic'
    }
    managementIpConfiguration: {
      name: 'mgmntipconfig'
      properties: {
        publicIPAddress: {
          id: firewallManagementPip.id
        }
        subnet: {
          id: firewallManagementSubnetId
        }
      }
    }
    firewallPolicy: {
      id: fwallPolicy.id
    }
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: firewall
  name: 'diagnostics'
  properties: {
    workspaceId: logAnalyticsId
    // Route to resource-specific tables (AZFWNetworkRule, AZFWApplicationRule,
    // AZFWNatRule, AZFWDnsQuery, ...) instead of the legacy AzureDiagnostics table.
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

/*
  ==========================================================================
  Firewall rule collections — deny-by-default for the agent subnet.
  ==========================================================================
  Azure Firewall has an implicit final DENY: any flow not matched by an Allow
  rule is dropped. We use that to lock down the agent subnet while leaving the
  dev VM and App Service spoke unrestricted:

    * DNAT (unchanged): inbound management HTTPS -> YARP proxy.
    * Network rules:
        - Unrestricted-Net-Out: non-agent sources (dev VM + App Service spoke)
          keep general outbound on all non-web ports (legacy behaviour).
        - Agent-Net-Allow: the agent subnet may reach ONLY the approved Azure
          service tags on 443/TCP. No FQDNs, no wildcards, no port 80.
    * Application rules:
        - Unrestricted-App-Out: non-agent sources keep general web egress.
        - App-AgentAllow: the agent subnet is allowed ONLY the exact Agent 365
          telemetry FQDN (agent365.svc.cloud.microsoft) over HTTPS, filtered by
          TLS SNI. Foundry forbids TLS *inspection*, but SNI-based FQDN filtering
          needs no decryption, so this is compliant. This is the real boundary
          for A365 egress — the agent NSG can only scope to the broad
          AzureFrontDoor.Frontend service tag, so the firewall pins the hostname.
          All other agent L7/FQDN egress falls through to the implicit deny.

  Service tags used for the agent are the documented Foundry/ACA requirements:
  https://learn.microsoft.com/azure/container-apps/firewall-integration
  https://learn.microsoft.com/azure/foundry/how-to/managed-virtual-network#required-outbound-rules
  ==========================================================================
*/
resource policyRuleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = {
  parent: fwallPolicy
  name: 'defaultRuleGroup'
  properties: {
    priority: 100
    ruleCollections: [
      // NAT rules (NAT collection)
      {
        name: 'Nat-DNAT-ManagementHttps'
        ruleCollectionType: 'FirewallPolicyNatRuleCollection'
        priority: 200
        action: {
          type: 'DNAT'
        }
        rules: [
          {
            ruleType: 'NatRule'
            name: 'DNAT-ManagementHttps'
            description: 'DNAT for management HTTPS'
            sourceAddresses: ['*']
            ipProtocols: ['TCP']
            destinationAddresses: [
              firewallPip.properties.ipAddress
            ]
            destinationPorts: ['443']
            translatedFqdn: yarpProxyFqdn
            translatedPort: '443'
          }
        ]
      }
      // Network rules (Filter collection) — non-agent sources stay unrestricted.
      {
        name: 'Net-UnrestrictedNonAgent'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 300
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'AllowNonAgentNonHttpOut'
            description: 'Dev VM + App Service spoke: allow general outbound except 80/443 (unchanged legacy behaviour).'
            sourceAddresses: unrestrictedSourceCidrs
            destinationAddresses: ['*']
            destinationPorts: ['1-79', '81-442', '444-65535']
            ipProtocols: ['Any']
          }
        ]
      }
      // Network rules (Filter collection) — agent subnet locked to service tags on 443.
      {
        name: 'Net-AgentAllow'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 310
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'AllowAgentServiceTagsHttps'
            description: 'Agent subnet: allow ONLY the approved Azure service tags on 443/TCP. Everything else hits the implicit deny.'
            sourceAddresses: [
              agentSubnetCidr
            ]
            destinationAddresses: agentEgressServiceTags
            destinationPorts: ['443']
            ipProtocols: ['TCP']
          }
        ]
      }
      // Application rules (Filter collection) — non-agent sources stay unrestricted.
      {
        name: 'App-UnrestrictedNonAgent'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 400
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            description: 'Dev VM + App Service spoke: allow general web egress (unchanged legacy behaviour).'
            name: 'AllowNonAgentWebOut'
            sourceAddresses: unrestrictedSourceCidrs
            protocols: [
              { port: 443, protocolType: 'Https' }
              { port: 80, protocolType: 'Http' }
            ]
            targetFqdns: [
              '*'
            ]
          }
        ]
      }
      // Application rules (Filter collection) — agent subnet pinned to the exact A365 FQDN.
      // This is the REAL enforcement point for A365 telemetry: the NSG can only scope to
      // the broad AzureFrontDoor.Frontend service tag (L3/L4), but the firewall filters by
      // TLS SNI (no TLS inspection — Foundry-compliant), so egress to Azure Front Door is
      // constrained to this single hostname and nothing else. Exact FQDN, no wildcard.
      {
        name: 'App-AgentAllow'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 410
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            description: 'Agent subnet: allow ONLY Agent 365 (A365) observability telemetry to agent365.svc.cloud.microsoft over HTTPS (SNI-pinned). All other agent L7/FQDN egress hits the implicit deny.'
            name: 'AllowAgent365Telemetry'
            sourceAddresses: [
              agentSubnetCidr
            ]
            protocols: [
              { port: 443, protocolType: 'Https' }
            ]
            targetFqdns: [
              'agent365.svc.cloud.microsoft'
            ]
          }
        ]
      }
    ]
  }
}

/*
  ==========================================================================
  OPTIONAL: model-gateway rule collection group (only when enableModelGateway).
  ==========================================================================
  Kept in a SEPARATE rule-collection group (distinct priority) so the core
  locked-down rules above are untouched when the gateway is disabled.

    * Net-AgentToApimGateway: the agent subnet may reach the APIM inbound
      private endpoint (in the gateway spoke pe-subnet) on 443/TCP. This is the
      only cross-spoke path — the agent force-tunnels here via its 0.0.0.0/0 UDR
      and returns symmetrically (pe-subnet has a UDR back to the firewall).
    * Net-ApimPlatformEgress: the APIM v2 outbound-integration subnet force-tunnels
      0.0.0.0/0 to the firewall, so allow its platform dependencies / MI token
      egress to the approved service tags on 443. Backend calls to the provider
      Foundry PE stay intra-VNet and never reach the firewall.
  ==========================================================================
*/
resource modelGatewayRuleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = if (enableModelGateway) {
  parent: fwallPolicy
  name: 'modelGatewayRuleGroup'
  properties: {
    priority: 200
    ruleCollections: [
      {
        name: 'Net-AgentToApimGateway'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 320
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'AllowAgentToApimInboundPE'
            description: 'Agent subnet: reach the APIM inbound private endpoint in the gateway spoke pe-subnet on 443/TCP.'
            sourceAddresses: [
              agentSubnetCidr
            ]
            destinationAddresses: [
              modelGatewayPeSubnetCidr
            ]
            destinationPorts: ['443']
            ipProtocols: ['TCP']
          }
        ]
      }
      {
        name: 'Net-ApimPlatformEgress'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 330
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'AllowApimPlatformEgress'
            description: 'APIM v2 outbound-integration subnet: allow platform dependency + MI token egress to approved service tags on 443/TCP.'
            sourceAddresses: [
              modelGatewayApimSubnetCidr
            ]
            destinationAddresses: apimEgressServiceTags
            destinationPorts: ['443']
            ipProtocols: ['TCP']
          }
        ]
      }
    ]
  }
  dependsOn: [
    policyRuleCollectionGroup
  ]
}

output publicIpV4 string = firewallPip.properties.ipAddress
output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
