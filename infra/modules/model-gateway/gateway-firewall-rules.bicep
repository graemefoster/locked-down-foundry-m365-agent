/*
  ==========================================================================
  Gateway firewall rules — ALWAYS deployed (APIM is always-on and shared).
  ==========================================================================
  A single rule-collection-group holding every APIM/gateway/Teams network rule.
  It lives in its OWN module (rather than beside the default rule group in
  firewall.bicep) so main.bicep can order it AFTER the APIM deployment. APIM
  Standard v2 takes ~15-45 min to provision, which puts a long settle window
  between the two rule-collection-group PUTs on this policy. Azure Firewall
  (especially Basic tier) can transiently fault a rule-collection-group PUT
  ("faulted referenced firewalls") when the underlying firewall is still settling
  from a prior PUT; sequencing this behind APIM gives that settle time. Keeping
  ALL gateway rules in ONE group (instead of one group per scenario) avoids
  multiple back-to-back RCG PUTs, which is the main trigger for that fault.

    * Net-ApimPlatformEgress (always): the APIM v2 outbound-integration subnet
      force-tunnels 0.0.0.0/0 to the firewall, so allow its platform dependency /
      MI-token egress to the approved service tags on 443. Required for APIM to
      stay healthy even when neither optional scenario routes traffic through it.
    * Net-AgentToApimGateway (model-gateway scenario): the agent subnet may reach
      the APIM inbound private endpoint (gateway spoke pe-subnet) on 443/TCP. The
      agent force-tunnels here via its 0.0.0.0/0 UDR and returns symmetrically
      (gateway pe-subnet has a UDR back to the firewall).
    * Net-ApimToFoundryPe (Teams inbound scenario): the APIM outbound subnet may
      reach the PRIMARY Foundry account private endpoint (foundry spoke pe-subnet)
      on 443/TCP, so APIM can forward Teams/M365 activities to the agent's
      activityProtocol endpoint. Return routing is made symmetric by a UDR on the
      foundry pe-subnet (see foundry-spoke-vnet.bicep, apimSubnetCidr param).
    * App-ApimPkiTelemetry (always): APIM v2 does TLS cert-chain validation
      (CRL / OCSP / AIA cert-issuer downloads) over HTTP:80 to the Microsoft PKI
      hosts and emits platform telemetry over HTTPS:443. These are FQDN (L7) flows,
      so they need APPLICATION rules — the service-tag NETWORK rules never match
      them, so without this collection they hit the implicit deny (observed live).

  The last two rules are harmless when their scenario is disabled (the source
  simply never initiates the flow); keeping them unconditional avoids extra RCG
  PUTs and keeps the private-VNet blast radius negligible.
  ==========================================================================
*/

@description('Name of the existing hub firewall policy to attach the gateway rule collection group to.')
param firewallPolicyName string

@description('Agent subnet CIDR. Allowed to reach the APIM inbound private endpoint on 443.')
param agentSubnetCidr string

@description('CIDR of the gateway spoke pe-subnet (APIM inbound PE). The agent subnet is allowed to reach this on 443.')
param modelGatewayPeSubnetCidr string

@description('CIDR of the gateway spoke apim-subnet (APIM v2 outbound VNet integration). Allowed platform egress on 443, and source of the Teams forward to the Foundry PE.')
param modelGatewayApimSubnetCidr string

@description('CIDR of the primary Foundry spoke pe-subnet (Foundry account PE). The APIM outbound subnet is allowed to reach this on 443 for the Teams inbound path.')
param foundryPeSubnetCidr string

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

// APIM v2 performs TLS certificate-chain validation (CRL / OCSP / AIA cert-issuer
// downloads) over plain HTTP:80 against the Microsoft PKI hosts, and emits platform
// telemetry over HTTPS:443. These are FQDN (L7) flows, so they need APPLICATION rules
// — the service-tag NETWORK rules above never match them and they were being denied
// (observed: HTTP:80 to www.microsoft.com/pkiops/*, crl2.microsoft.com, caissuers.microsoft.com;
// HTTPS:443 to mobile.events.data.microsoft.com). CRL/OCSP failures normally soft-fail,
// but denying them adds latency and noise, so allow the documented PKI + telemetry set.
var apimPkiFqdns = [
  'www.microsoft.com'
  'crl.microsoft.com'
  'crl2.microsoft.com'
  'caissuers.microsoft.com'
  'oneocsp.microsoft.com'
  'ocsp.msocsp.com'
]
var apimTelemetryFqdns = [
  'mobile.events.data.microsoft.com'
]
// APIM validate-jwt (Teams inbound API) fetches the Bot Framework IdP's OpenID Connect
// metadata + signing keys from this host to cryptographically verify the Bot Channel
// Adapter JWT. APIM outbound is force-tunnelled through the firewall, so without this
// application rule the metadata fetch is denied and validate-jwt returns 401 for every
// inbound Teams activity (observed: 10.3.0.x -> login.botframework.com Deny). The bot IdP's
// openid-configuration keeps jwks_uri on the same host, so this single FQDN is sufficient.
var apimBotFrameworkFqdns = [
  'login.botframework.com'
]

resource fwallPolicy 'Microsoft.Network/firewallPolicies@2025-01-01' existing = {
  name: firewallPolicyName
}

resource gatewayRuleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = {
  parent: fwallPolicy
  name: 'gatewayRuleGroup'
  properties: {
    priority: 200
    ruleCollections: [
      {
        name: 'Net-ApimPlatformEgress'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 320
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
      {
        name: 'Net-AgentToApimGateway'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 330
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'AllowAgentToApimInboundPE'
            description: 'Model gateway: agent subnet reaches the APIM inbound private endpoint in the gateway spoke pe-subnet on 443/TCP.'
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
        name: 'Net-ApimToFoundryPe'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 340
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'AllowApimToFoundryInboundPE'
            description: 'Teams inbound: APIM outbound subnet reaches the primary Foundry account private endpoint (foundry spoke pe-subnet) on 443/TCP to forward activities to the agent activityProtocol endpoint.'
            sourceAddresses: [
              modelGatewayApimSubnetCidr
            ]
            destinationAddresses: [
              foundryPeSubnetCidr
            ]
            destinationPorts: ['443']
            ipProtocols: ['TCP']
          }
        ]
      }
      {
        name: 'App-ApimPkiTelemetry'
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        priority: 350
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'AllowApimPkiCertChain'
            description: 'APIM v2 TLS cert-chain validation: CRL / OCSP / AIA cert-issuer downloads to the Microsoft PKI hosts over HTTP:80 (and HTTPS:443 where offered).'
            sourceAddresses: [
              modelGatewayApimSubnetCidr
            ]
            protocols: [
              { protocolType: 'Http', port: 80 }
              { protocolType: 'Https', port: 443 }
            ]
            targetFqdns: apimPkiFqdns
          }
          {
            ruleType: 'ApplicationRule'
            name: 'AllowApimTelemetry'
            description: 'APIM v2 platform telemetry egress over HTTPS:443.'
            sourceAddresses: [
              modelGatewayApimSubnetCidr
            ]
            protocols: [
              { protocolType: 'Https', port: 443 }
            ]
            targetFqdns: apimTelemetryFqdns
          }
          {
            ruleType: 'ApplicationRule'
            name: 'AllowApimBotFrameworkOidc'
            description: 'Teams inbound JWT validation: APIM validate-jwt fetches the Bot Framework IdP OpenID Connect metadata + signing keys over HTTPS:443. Without this the metadata fetch is denied and every inbound Teams activity fails validation with 401.'
            sourceAddresses: [
              modelGatewayApimSubnetCidr
            ]
            protocols: [
              { protocolType: 'Https', port: 443 }
            ]
            targetFqdns: apimBotFrameworkFqdns
          }
        ]
      }
    ]
  }
}
