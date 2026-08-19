/*
  Teams / M365 publish: APIM inbound API + policy
  -----------------------------------------------
  The inbound path for publishing a private Foundry agent to Microsoft Teams /
  M365 Copilot (see the Learn article linked in README.md / docs/NETWORKING.md):

    Bot Channel Adapter -> Azure Bot Service -> YARP (public App Service)
      -> THIS APIM API -> the Foundry agent activityProtocol endpoint (private PE).

  Path-routed: each published agent's bot posts to '<apiPath>/{agentName}'; this single
  API + policy rewrites the URI to that agent's activityProtocol endpoint (deriving the
  agent from the {agentName} path segment) and forwards to the primary Foundry account
  over its private endpoint (APIM outbound VNet integration -> firewall -> foundry PE).
  One API serves every published agent — no per-agent re-provision.

  Auth posture:
    * validate-jwt (defense-in-depth) — the Bot Channel Adapter presents a signed
      Bot Framework JWT. We validate it at the APIM edge using the Bot Framework
      OpenID metadata, pinning issuer 'https://api.botframework.com' and (when
      botAppIds are supplied) the audience against a SET of the published bots'
      Microsoft App IDs (each = an agent identity principal_id, which only exists
      AFTER agent seeding). botAppIds defaults to [] here (issuer-only validation)
      and the deploy-agent-network.yml network workflow rebuilds the full audience
      allowlist live once the agents are seeded and their bots created.
    * The ORIGINAL Authorization header (bot JWT) is forwarded to Foundry
      unchanged — Foundry validates the token on your behalf and authorizes the
      end user. We do NOT swap in a managed-identity token.

  Modelled on stages/30-governance/model-gateway/apim-api-policy.bicep (inert @@TOKEN@@
  placeholders + replace(), because Bicep does not interpolate ${...} inside
  triple-quoted strings).
*/

@description('Name of the existing APIM instance')
param apimName string

@description('API path (also used as the API name) that YARP forwards Teams traffic to, e.g. "teams". Env-suffixed internally so dev/test each get their own Teams inbound API on the shared APIM instance.')
param apiPath string = 'teams'

@description('Environment token (e.g. "dev" / "test") that suffixes the Teams API name/path + backend id so the two per-project Teams inbound APIs on the shared account do not collide.')
param env string

@description('Name of the primary Foundry (Cognitive Services) account that hosts the agent')
param foundryAccountName string

@description('Name of the primary Foundry project')
param projectName string

@description('API version for the agent activityProtocol endpoint')
param activityApiVersion string = '2025-05-15-preview'

@description('List of bot Microsoft App IDs (= each published agent identity principal_id) to allow as validate-jwt audiences. Each published agent has its own bot, so this is a set. Empty = validate issuer only (the deploy-agent-network.yml network workflow rebuilds the full audience set live once agents are seeded).')
param botAppIds array = []

@description('Expected Entra tenant GUID. When set, the policy asserts the Bot Framework token serviceurl is scoped to this tenant (the GUID appears in the serviceurl path, e.g. smba.trafficmanager.net/amer/<tenantId>/) and rejects anything else with 403 — single-tenant lockdown. Empty = skip the assertion.')
param expectedTenantId string = ''

// Backend = the primary Foundry account private endpoint (services.ai.azure.com),
// reached by APIM outbound VNet integration force-tunnelled through the firewall.
// Modelled as a first-class APIM `backend` entity (not a hardwired base-url) so
// tooling can discover the APIM -> Foundry edge; the policy references it by ID.
var backendBaseUrl = 'https://${foundryAccountName}.services.ai.azure.com'
var backendId = 'foundry-${foundryAccountName}-${env}'
// Env-suffixed API name/path so dev + test each expose a distinct Teams inbound API.
var envApiPath = '${apiPath}-${env}'
// Path-routed: the {agentName} token is a URL-template parameter the bot supplies in the
// messaging-endpoint path (/teams/{agentName}). APIM substitutes it into the rewrite target,
// so ONE API + policy serves every published agent (no per-agent re-provision). ${projectName}
// / ${activityApiVersion} are baked at deploy time; {agentName} is left literal for APIM.
var rewriteTarget = '/api/projects/${projectName}/agents/{agentName}/endpoint/protocols/activityProtocol?api-version=${activityApiVersion}'

// Multi-audience allowlist: each published agent has its own bot (own App ID), so
// validate-jwt accepts a SET of audiences. Empty list => issuer-only (audiences omitted).
var audienceEntries = [for id in botAppIds: '<audience>${id}</audience>']
var audienceBlock = empty(botAppIds) ? '' : '<audiences>${join(audienceEntries, '')}</audiences>'

// Single-tenant lockdown: the Bot Framework token has no `tid` claim, but its
// serviceurl path embeds the caller's tenant GUID (smba.trafficmanager.net/<region>/<tenantId>/).
// serviceurl is signed by Bot Framework (validated above), so asserting the tenant GUID is
// present in it rejects activities from any other tenant with 403. Region-agnostic (matches
// the GUID, not the full URL). Inner string literals use &quot; so the XML attribute stays valid.
var serviceUrlAssertBlock = empty(expectedTenantId)
  ? ''
  : '<choose><when condition="@{ var c = ((Jwt)context.Variables[&quot;jwt&quot;]).Claims; var s = c.ContainsKey(&quot;serviceurl&quot;) ? c[&quot;serviceurl&quot;].FirstOrDefault() : &quot;&quot;; return string.IsNullOrEmpty(s) || !s.Contains(&quot;@@TENANTID@@&quot;); }"><return-response><set-status code="403" reason="Forbidden" /><set-body>Unauthorized: Bot Framework serviceurl is not scoped to the expected tenant.</set-body></return-response></when></choose>'

var policyTemplate = '''<policies>
  <inbound>
    <base />
    <validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized: Bot Framework token failed validation." output-token-variable-name="jwt">
      <openid-config url="https://login.botframework.com/v1/.well-known/openidconfiguration" />
      @@AUDIENCES@@
      <issuers>
        <issuer>https://api.botframework.com</issuer>
      </issuers>
    </validate-jwt>
    @@SERVICEURLASSERT@@
    <set-backend-service backend-id="@@BACKENDID@@" />
    <rewrite-uri template="@@REWRITE@@" copy-unmatched-params="false" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>'''

var serviceUrlAssertRendered = replace(serviceUrlAssertBlock, '@@TENANTID@@', expectedTenantId)

var renderedPolicy = replace(
  replace(
    replace(
      replace(policyTemplate, '@@AUDIENCES@@', audienceBlock),
      '@@SERVICEURLASSERT@@',
      serviceUrlAssertRendered
    ),
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
  name: envApiPath
  properties: {
    displayName: 'Teams / M365 inbound (${env})'
    path: envApiPath
    protocols: [
      'https'
    ]
    // The Bot Framework adapter presents its own JWT; there is no APIM subscription key.
    subscriptionRequired: false
    // No serviceUrl: the policy routes to the `foundryBackend` backend by ID, so the
    // Foundry edge is expressed once, as a first-class APIM backend entity.
  }
}

// Path-routed messaging endpoint: each bot posts to /teams/{agentName}. The {agentName}
// URL-template parameter is substituted into the rewrite target, so ONE operation + policy
// serves every published agent.
resource messagesOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: teamsApi
  name: 'post-activities'
  properties: {
    displayName: 'Post Activities'
    method: 'POST'
    urlTemplate: '/{agentName}'
    templateParameters: [
      {
        name: 'agentName'
        description: 'Seeded Foundry agent name; its activityProtocol endpoint is the backend.'
        type: 'string'
        required: true
      }
    ]
    description: 'Bot Channel Adapter posts Teams/M365 activities to /teams/{agentName}; forwarded to that agent activityProtocol endpoint.'
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
