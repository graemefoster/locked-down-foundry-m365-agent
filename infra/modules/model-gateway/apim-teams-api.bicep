/*
  Teams / M365 publish: APIM inbound API + policy
  -----------------------------------------------
  The inbound path for publishing a private Foundry agent to Microsoft Teams /
  M365 Copilot (see the Learn article linked in README.md / NETWORKING.md):

    Bot Channel Adapter -> Azure Bot Service -> YARP (public App Service)
      -> THIS APIM API -> primary Foundry agent activityProtocol endpoint (private PE).

  YARP forwards the bot's POST to APIM path '<apiPath>'; this API rewrites the URI
  to the agent's activityProtocol endpoint and forwards to the primary Foundry
  account over its private endpoint (APIM outbound VNet integration -> firewall ->
  foundry PE).

  Auth posture:
    * validate-jwt (defense-in-depth) — the Bot Channel Adapter presents a signed
      Bot Framework JWT. We validate it at the APIM edge using the Bot Framework
      OpenID metadata, pinning issuer 'https://api.botframework.com' and (when
      botAppId is supplied) the audience = the bot's Microsoft App ID. The bot's
      App ID is the agent identity principal_id, which only exists AFTER agent
      seeding, so botAppId defaults to '' here (issuer-only validation) and the
      publish hook pins the audience live once it knows the principal_id.
    * The ORIGINAL Authorization header (bot JWT) is forwarded to Foundry
      unchanged — Foundry validates the token on your behalf and authorizes the
      end user. We do NOT swap in a managed-identity token.

  Modelled on modules/model-gateway/apim-api-policy.bicep (inert @@TOKEN@@
  placeholders + replace(), because Bicep does not interpolate ${...} inside
  triple-quoted strings).
*/

@description('Name of the existing APIM instance')
param apimName string

@description('API path (also used as the API name) that YARP forwards Teams traffic to, e.g. "teams"')
param apiPath string = 'teams'

@description('Name of the primary Foundry (Cognitive Services) account that hosts the agent')
param foundryAccountName string

@description('Name of the primary Foundry project')
param projectName string

@description('Name of the agent to route Teams/M365 traffic to (its activityProtocol endpoint is the backend)')
param agentName string

@description('API version for the agent activityProtocol endpoint')
param activityApiVersion string = '2025-05-15-preview'

@description('Bot Microsoft App ID (= agent identity principal_id) to pin as the validate-jwt audience. Empty = validate issuer only (the publish hook pins the audience live once the agent is seeded).')
param botAppId string = ''

// Backend = the primary Foundry account private endpoint (services.ai.azure.com),
// reached by APIM outbound VNet integration force-tunnelled through the firewall.
// Modelled as a first-class APIM `backend` entity (not a hardwired base-url) so
// tooling can discover the APIM -> Foundry edge; the policy references it by ID.
var backendBaseUrl = 'https://${foundryAccountName}.services.ai.azure.com'
var backendId = 'foundry-${foundryAccountName}'
var rewriteTarget = '/api/projects/${projectName}/agents/${agentName}/endpoint/protocols/activityProtocol?api-version=${activityApiVersion}'

var audienceBlock = empty(botAppId)
  ? ''
  : '<audiences><audience>@@BOTAPPID@@</audience></audiences>'

var policyTemplate = '''<policies>
  <inbound>
    <base />
    <validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized: Bot Framework token failed validation.">
      <openid-config url="https://login.botframework.com/v1/.well-known/openidconfiguration" />
      @@AUDIENCES@@
      <issuers>
        <issuer>https://api.botframework.com</issuer>
      </issuers>
    </validate-jwt>
    <set-backend-service backend-id="@@BACKENDID@@" />
    <rewrite-uri template="@@REWRITE@@" copy-unmatched-params="false" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>'''

var audienceRendered = replace(audienceBlock, '@@BOTAPPID@@', botAppId)

var renderedPolicy = replace(
  replace(
    replace(policyTemplate, '@@AUDIENCES@@', audienceRendered),
    '@@BACKENDID@@',
    backendId
  ),
  '@@REWRITE@@',
  rewriteTarget
)

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

// First-class backend for the primary Foundry account. The policy targets it by ID.
resource foundryBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: backendId
  properties: {
    title: 'Primary Foundry agent (activityProtocol)'
    description: 'Primary Foundry account private endpoint; APIM rewrites to the agent activityProtocol endpoint and forwards over VNet integration -> firewall -> Foundry PE.'
    protocol: 'http'
    url: backendBaseUrl
  }
}

resource teamsApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: apiPath
  properties: {
    displayName: 'Teams / M365 inbound'
    path: apiPath
    protocols: [
      'https'
    ]
    // The Bot Framework adapter presents its own JWT; there is no APIM subscription key.
    subscriptionRequired: false
    // No serviceUrl: the policy routes to the `foundryBackend` backend by ID, so the
    // Foundry edge is expressed once, as a first-class APIM backend entity.
  }
}

// The bot posts every activity to the single messaging endpoint (POST). The API
// path is the messaging endpoint; the policy rewrites to the activityProtocol path.
resource messagesOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: teamsApi
  name: 'post-activities'
  properties: {
    displayName: 'Post Activities'
    method: 'POST'
    urlTemplate: '/'
    description: 'Bot Channel Adapter posts Teams/M365 activities here; forwarded to the agent activityProtocol endpoint.'
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: teamsApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: renderedPolicy
  }
  dependsOn: [
    messagesOperation
    foundryBackend
  ]
}

output apiName string = teamsApi.name
output apiPath string = teamsApi.properties.path
