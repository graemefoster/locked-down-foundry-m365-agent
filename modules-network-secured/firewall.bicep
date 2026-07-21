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

// The optional model-gateway rule collection group lives in its own module
// (model-gateway/model-gateway-firewall-rules.bicep) so main.bicep can sequence
// it AFTER the APIM deployment, giving the firewall a long settle window between
// the two rule-collection-group PUTs on this policy.

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

output publicIpV4 string = firewallPip.properties.ipAddress
output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
