/*
  Azure Bot Service for a Teams / M365-published Foundry agent
  ------------------------------------------------------------
  Deployed HOST-SIDE by the azd postdeploy hook (hooks/postdeploy.ps1) via
  `az deployment group create`. It lives in hooks/ (beside that hook), NOT in
  scripts/ — scripts/ is reserved for code executed ON the private VM, which may
  only call Foundry REST APIs. This Bicep is control-plane work and runs from the
  azd host, outside the VNet. It is not wired into infra/main.bicep because its
  `msaAppId` (the agent identity principal_id) only exists AFTER agent seeding, so
  the value is discovered live by the hook.

  See: https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot-virtual-network (Step 2)

  In THIS locked-down topology the bot's `endpoint` is NOT the Foundry agent's
  private activityProtocol URL (as the article's happy path uses with DNS
  trickery). Instead it is the PUBLIC YARP proxy FQDN + '/teams', which forwards
  to APIM -> the agent activityProtocol private endpoint. This avoids custom DNS
  / certificates at the cost of an extra public hop (documented tradeoff).
*/

@description('Name of the Azure Bot Service resource.')
param botName string

@description('Display name shown in Teams / M365 Copilot.')
param displayName string

@description('Agent identity principal ID (instance_identity.principal_id) — the bot Microsoft App ID.')
param msaAppId string

@description('Microsoft Entra tenant ID the single-tenant bot registration belongs to.')
param tenantId string

@description('Bot messaging endpoint. In this topology: https://<yarp-public-fqdn>/teams')
param endpoint string

@description('Bot Service SKU.')
param botServiceSku string = 'F0'

@description('Log Analytics workspace resource ID for Bot Service diagnostics (BotRequest / DependencyRequest logs). Empty string skips the diagnostic setting.')
param logAnalyticsWorkspaceId string = ''

resource botService 'Microsoft.BotService/botServices@2022-09-15' = {
  name: botName
  kind: 'azurebot'
  location: 'global'
  sku: {
    name: botServiceSku
  }
  properties: {
    displayName: displayName
    endpoint: endpoint
    msaAppId: msaAppId
    msaAppTenantId: tenantId
    msaAppType: 'SingleTenant'
    publicNetworkAccess: 'Disabled'
  }
}

resource botServiceMsTeamsChannel 'Microsoft.BotService/botServices/channels@2021-03-01' = {
  parent: botService
  location: 'global'
  name: 'MsTeamsChannel'
  properties: {
    channelName: 'MsTeamsChannel'
  }
}

// Diagnostic settings: send BotRequest (channel adapter -> bot -> messaging endpoint)
// logs to Log Analytics so inbound Teams / M365 delivery can be traced. Conditional so
// the template still deploys if no workspace is supplied.
resource botDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  scope: botService
  name: 'bot-diag'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

@description('ARM resource ID of the bot — passed as botServiceArmId to the Microsoft 365 publish API.')
output botServiceArmId string = botService.id
