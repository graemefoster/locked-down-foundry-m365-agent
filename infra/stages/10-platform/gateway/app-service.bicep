param location string
param logAnalyticsId string
param appInsightsName string
param appServiceDelegationSubnetId string
param aspName string

@description('APIM gateway base URL (e.g. https://apim-xxx.azure-api.net) the YARP proxy forwards Teams traffic to.')
param apimGatewayUrl string = ''

@description('Optional public IP (bare IPv4 or CIDR) of the provisioning operator to allow into the public YARP edge for dev/test, IN ADDITION to the Microsoft Teams inbound ranges. Empty (default) = Teams-only, no operator hole. Set opt-in via DEPLOYER_PUBLIC_IP (preprovision hook).')
param deployerPublicIp string = ''

// Microsoft Teams "Required" published IP ranges — the source ranges the Bot Channel Adapter
// uses to POST activities to the messaging endpoint. From the Microsoft 365 URLs & IP address
// ranges list, service area "Skype" / display name "Microsoft Teams" (endpoint sets 11-12).
// NOT the AzureBotService service tag: that tag covers DirectLine + the Bot Service token
// cache, which this Teams-channel delivery path does not use, and it does NOT include the
// 52.112.0.0/14 / 52.122.0.0/15 ranges the adapter actually connects from.
// Source: https://learn.microsoft.com/microsoft-365/enterprise/urls-and-ip-address-ranges
// (refresh via https://endpoints.office.com/endpoints/worldwide — serviceArea == 'Skype', required == true)
var teamsInboundIpRanges = [
  '52.112.0.0/14'
  '52.122.0.0/15'
  '2603:1027::/48'
  '2603:1037::/48'
  '2603:1047::/48'
  '2603:1057::/48'
  '2603:1063::/38'
  '2620:1ec:40::/42'
  '2620:1ec:6::/48'
]

// YARP is the PUBLIC Teams/M365 messaging entry point (never private-endpointed — this is the
// way in from the outside). It forwards to the APIM Teams API (which validates the Bot Framework
// JWT and forwards to the agent activityProtocol endpoint), with inbound IP-restricted to the
// Microsoft Teams "Required" published ranges.
var yarpPublicNetworkAccess = 'Enabled'
var yarpReverseProxyAddress = '${apimGatewayUrl}/'
var teamsInboundIpRules = [
  for (cidr, i) in teamsInboundIpRanges: {
    ipAddress: cidr
    action: 'Allow'
    priority: 100 + i
    name: 'AllowTeamsInbound-${i}'
    description: 'Microsoft Teams Required inbound range'
  }
]
// Opt-in: allow the provisioning operator's own public IP into the PUBLIC YARP edge so they can
// reach the /agents/<name> and /teams/<name> routes for dev/test. This is only the NETWORK layer:
// a caller still needs a valid Entra token (audience https://ai.azure.com) AND to be in the
// deny-by-default token-limit allowlist to actually invoke an agent through APIM. Empty = no rule.
var deployerIpRules = empty(deployerPublicIp)
  ? []
  : [
      {
        ipAddress: contains(deployerPublicIp, '/') ? deployerPublicIp : '${deployerPublicIp}/32'
        action: 'Allow'
        priority: 90
        name: 'AllowDeployerIp'
        description: 'Opt-in operator public IP (dev/test YARP edge access)'
      }
    ]
var yarpIpRestrictions = concat(teamsInboundIpRules, deployerIpRules)

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource aspTest 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: aspName
  location: location
  sku: {
    name: 'P0V3'
    capacity: 1
  }
  properties: {
    zoneRedundant: false
    //make it linux
    reserved: true
  }
}

//and one web-app where we will deploy the YARP proxy to later
resource webApp 'Microsoft.Web/sites@2025-03-01' = {
  name: 'yarp-${aspName}'
  location: location
  kind: 'app,linux'
  // azd maps the 'gateway' service (azure.yaml) to this web app via this tag, then `dotnet publish`
  // + zip-deploys apps/sample-gateway (no container image).
  tags: {
    'azd-service-name': 'gateway'
  }
  properties: {
    serverFarmId: aspTest.id
    siteConfig: {
      // .NET code stack (was a DOCKER image). Source lives in apps/sample-gateway (net10 YARP);
      // azd publishes and zip-deploys it.
      linuxFxVersion: 'DOTNETCORE|10.0'
      publicNetworkAccess: yarpPublicNetworkAccess
      ipSecurityRestrictionsDefaultAction: 'Deny'
      ipSecurityRestrictions: yarpIpRestrictions
      // The MAIN site stays public (it is the Teams/M365 ingress), but the SCM (Kudu) site is
      // deny-by-default so the deploy endpoint is NOT world-reachable at rest. The predeploy hook
      // adds a temporary allow rule for the deployer IP so azd can zip-deploy, then the postdeploy
      // hook removes it (reverting to deny-all on SCM).
      scmIpSecurityRestrictionsUseMain: false
      scmIpSecurityRestrictionsDefaultAction: 'Deny'
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'XDT_MicrosoftApplicationInsights_Mode'
          value: 'recommended'
        }
        {
          name: 'XDT_MicrosoftApplicationInsights_PreemptSdk'
          value: '1'
        }
        {
          name: 'ReverseProxy__Clusters__cluster1__Destinations__destination1__Address'
          value: yarpReverseProxyAddress
        }
      ]
    }
    httpsOnly: true
    virtualNetworkSubnetId: appServiceDelegationSubnetId
    outboundVnetRouting: {
      allTraffic: true
    }
  }
}

resource appDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: webApp
  name: 'diagnostics'
  properties: {
    workspaceId: logAnalyticsId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}


output aspId string = aspTest.id
output yarpWebAppFqdn string = webApp.properties.defaultHostName
output yarpWebAppName string = webApp.name
