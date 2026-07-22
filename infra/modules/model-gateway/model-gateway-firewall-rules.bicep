@description('Name of the existing hub firewall policy to attach the model-gateway rule collection group to.')
param firewallPolicyName string

@description('Agent subnet CIDR. Allowed to reach the APIM inbound private endpoint on 443.')
param agentSubnetCidr string

@description('CIDR of the gateway spoke pe-subnet (APIM inbound PE). The agent subnet is allowed to reach this on 443.')
param modelGatewayPeSubnetCidr string

@description('CIDR of the gateway spoke apim-subnet (APIM v2 outbound VNet integration). Allowed platform egress on 443.')
param modelGatewayApimSubnetCidr string

// Service tags APIM v2 may reach for platform dependencies / MI token acquisition
// when its outbound-integration subnet force-tunnels 0.0.0.0/0 through the firewall.
// AzureResourceManager is required for the dynamic model-discovery operations
// (GET /deployments), which call the provider account's ARM deployments API.
// Scoped to 443; anything else falls through to the implicit deny.
var apimEgressServiceTags = [
  'AzureActiveDirectory'
  'AzureResourceManager'
  'AzureMonitor'
  'Storage'
  'AzureKeyVault'
]

resource fwallPolicy 'Microsoft.Network/firewallPolicies@2025-01-01' existing = {
  name: firewallPolicyName
}

/*
  ==========================================================================
  Model-gateway rule collection group (deployed only when enableModelGateway).
  ==========================================================================
  This lives in its OWN module (rather than beside the default rule group in
  firewall.bicep) so main.bicep can order it AFTER the APIM deployment. APIM
  Standard v2 takes ~15-45 min to provision, which puts a long settle window
  between the two rule-collection-group PUTs on the same firewall policy. Azure
  Firewall (especially Basic tier) can transiently fault a rule-collection-group
  PUT ("faulted referenced firewalls") when the underlying firewall is still
  settling from a prior PUT; a plain dependsOn on the default group only orders
  them back-to-back and does not guarantee the firewall is idle. Sequencing this
  behind APIM gives that settle time for free.

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
resource modelGatewayRuleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = {
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
}
