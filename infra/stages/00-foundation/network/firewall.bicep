param firewallPipName string
param firewallMgmtPipName string
param firewallName string
param firewallPolicyName string
param location string = resourceGroup().location
param firewallSubnetId string
param firewallManagementSubnetId string
param logAnalyticsId string
param yarpProxyFqdn string

@description('Complete VNet and subnet CIDRs from the shared address plan.')
param addressPlan object

var agentSubnetCidr = addressPlan.foundry.agentSubnetCidr
var appServicePeSubnetCidr = addressPlan.appService.peSubnetCidr
var unrestrictedSourceCidrs = [
  addressPlan.foundry.vmSubnetCidr
  addressPlan.appService.vnetAddressPrefix
  addressPlan.foundry.deploymentScriptsSubnetCidr
]

// The optional model-gateway rule collection group lives in its own module
// (model-gateway/model-gateway-firewall-rules.bicep) so main.bicep can sequence
// it AFTER the APIM deployment, giving the firewall a long settle window between
// the two rule-collection-group PUTs on this policy.

// Service tags the agent subnet is permitted to reach on 443 (network rules). No FQDNs, no wildcards.
var agentEgressServiceTags = [
  'AzureActiveDirectory'
  'MicrosoftContainerRegistry'
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
        - App-AgentAllow: the agent subnet is allowed ONLY an explicit set of
          exact FQDNs over HTTPS, filtered by TLS SNI: Agent 365 telemetry
          (agent365.svc.cloud.microsoft), the Teams/Bot Framework reply host
          (smba.trafficmanager.net), the App Insights SDK settings endpoint
          (settings.sdk.monitor.azure.com), and Microsoft Container Registry
          (mcr.microsoft.com, *.data.mcr.microsoft.com) for hosted-agent image
          pulls. Foundry forbids TLS *inspection*, but SNI-based FQDN filtering
          needs no decryption, so this is compliant. These are the real boundary
          for agent L7 egress — the agent NSG can only scope to broad service
          tags (e.g. AzureFrontDoor.Frontend), so the firewall pins the hostnames.
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
          {
            ruleType: 'NetworkRule'
            name: 'AllowAgentToMcpPE'
            description: 'Agent subnet: reach the MCP web app inbound private endpoint (App Service spoke pe-subnet) on 443/TCP. Cross-spoke via the hub firewall; return is symmetric (App Service pe-subnet UDR back to firewall).'
            sourceAddresses: [
              agentSubnetCidr
            ]
            destinationAddresses: [
              appServicePeSubnetCidr
            ]
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
      // Application rules (Filter collection) — agent subnet pinned to required FQDNs.
      // A365 telemetry has no service tag for the hostname the client actually reaches, so
      // the NSG scopes to the AzureFrontDoor.Frontend tag and the firewall filters by TLS
      // SNI (no TLS inspection — Foundry-compliant).
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
          {
            ruleType: 'ApplicationRule'
            description: 'Agent subnet: allow the hosted agent to post activities back to Teams/Bot Framework channel connector (serviceUrl host) over HTTPS (SNI-pinned). Exact FQDN only, no wildcard.'
            name: 'AllowAgentTeamsReply'
            sourceAddresses: [
              agentSubnetCidr
            ]
            protocols: [
              { port: 443, protocolType: 'Https' }
            ]
            targetFqdns: [
              'smba.trafficmanager.net'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            description: 'Agent subnet: allow the Application Insights / OpenTelemetry SDK to fetch live-metrics, live-diagnostics and dynamic settings over HTTPS (SNI-pinned). Not covered by the AzureMonitor service tag. Exact FQDNs only, no wildcard.'
            name: 'AllowAgentMonitorSdkSettings'
            sourceAddresses: [
              agentSubnetCidr
            ]
            protocols: [
              { port: 443, protocolType: 'Https' }
            ]
            targetFqdns: [
              'settings.sdk.monitor.azure.com'
              'australiaeast.livediagnostics.monitor.azure.com'
            ]
          }
          {
            ruleType: 'ApplicationRule'
            description: 'Agent subnet: allow the hosted Container Apps agent runtime to pull base/runtime image layers from Microsoft Container Registry over HTTPS (SNI-pinned). MCR is fronted by a CDN whose IPs are not covered by the MicrosoftContainerRegistry service tag, so the network rule misses it and it must be pinned by FQDN here.'
            name: 'AllowAgentMcr'
            sourceAddresses: [
              agentSubnetCidr
            ]
            protocols: [
              { port: 443, protocolType: 'Https' }
            ]
            targetFqdns: [
              'mcr.microsoft.com'
              '*.data.mcr.microsoft.com'
            ]
          }
        ]
      }
    ]
  }
}

output publicIpV4 string = firewallPip.properties.ipAddress
output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
