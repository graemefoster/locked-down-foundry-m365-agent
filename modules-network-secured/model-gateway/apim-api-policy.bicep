/*
  Model-Gateway: APIM inference API + policy
  ------------------------------------------
  Defines the inference API on APIM and its policy:

    * Inbound: validate-azure-ad-token — verifies the caller presents a valid
      Entra token for the audience 'https://cognitiveservices.azure.com/' in this
      tenant. Optionally restricts to a specific caller app/client ID
      (projectMiClientId) when supplied. NOTE: a project's system-assigned MI does
      not expose its client/app ID in ARM (only the object/principal ID), so this
      is left optional — validate on tenant + audience by default, and pin to the
      client-application-id only if the caller can supply it.
    * set-backend-service — rewrites the upstream to the provider Foundry's private
      OpenAI endpoint (reached over the private endpoint via VNet integration).
    * authentication-managed-identity — APIM authenticates to the provider Foundry
      backend using its own system-assigned managed identity.

  The API is modelled on the foundry-samples byom-cross-region reference:
  operations are defined manually (no OpenAPI import); the deployment name is a
  URL-template parameter so the exposed model name is passed through in the path.
*/

@description('Name of the existing APIM instance')
param apimName string

@description('API path (also used as the API name), e.g. "inference"')
param apiPath string = 'inference'

@description('Base URL of the provider Foundry OpenAI endpoint, e.g. https://<account>.openai.azure.com/openai')
param backendBaseUrl string

@description('ARM resource ID of the provider Foundry (Cognitive Services) account. Used to back the dynamic model-discovery operations (GET /deployments) with the Azure Resource Manager control plane.')
param providerAccountResourceId string

@description('Audience for the inbound token and the backend managed-identity token. MUST match the audience the Foundry connection sends (no trailing slash).')
param tokenAudience string = 'https://cognitiveservices.azure.com'

@description('Optional caller app/client ID to restrict inbound callers (empty = validate tenant + audience only)')
param projectMiClientId string = ''

@description('Require an APIM subscription key (api-key header) IN ADDITION to the Entra JWT.')
param subscriptionRequired bool = true

@description('Primary key for the APIM subscription. Empty = do not create a managed subscription (APIM autogenerates keys).')
@secure()
param apiSubscriptionKey string = ''

@description('API version used for the ARM control-plane model-discovery calls (GET /deployments).')
param deploymentDiscoveryApiVersion string = '2023-05-01'

var tenantId = subscription().tenantId

var clientAppRestriction = empty(projectMiClientId)
  ? ''
  : '<client-application-ids><application-id>@@CLIENTID@@</application-id></client-application-ids>'

// NOTE: Bicep does NOT interpolate ${...} inside multi-line ('''...''') strings — the
// tokens would be emitted literally. So the template uses inert @@TOKEN@@ placeholders
// and replace() swaps in the resolved values (replace's arguments are single-line
// literals, so they are safe from interpolation too).
var policyTemplate = '''<policies>
  <inbound>
    <base />
    <validate-azure-ad-token tenant-id="@@TENANT@@" header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized: token failed validation.">
      @@CLIENT_APPS@@
      <audiences>
        <audience>@@AUDIENCE@@</audience>
        <audience>@@AUDIENCE@@/</audience>
      </audiences>
    </validate-azure-ad-token>
    <set-backend-service base-url="@@BACKEND@@" />
    <authentication-managed-identity resource="@@AUDIENCE@@" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>'''

var clientAppRendered = replace(clientAppRestriction, '@@CLIENTID@@', projectMiClientId)

var renderedPolicy = replace(
  replace(
    replace(
      replace(policyTemplate, '@@TENANT@@', tenantId),
      '@@CLIENT_APPS@@',
      clientAppRendered
    ),
    '@@AUDIENCE@@',
    tokenAudience
  ),
  '@@BACKEND@@',
  backendBaseUrl
)

// -------------------- Dynamic model discovery --------------------
// Foundry discovers models at runtime by calling GET /deployments (list) and
// GET /deployments/{deploymentName} (get) on this API. Those calls are routed to
// the Azure Resource Manager CONTROL plane for the provider account (not the
// data-plane openai endpoint) because ARM returns the AzureOpenAI-format deployment
// list Foundry expects. Each operation policy inherits the API-level inbound via
// <base/> (so the project-MI JWT + api-key are still enforced), then overrides the
// backend + managed-identity audience to ARM. Modelled on the foundry-samples
// apim-setup-guide-for-agents "Dynamic Model Discovery via APIM" section.
var armAudience = environment().resourceManager
// environment().resourceManager ends with '/'; providerAccountResourceId starts with
// '/subscriptions/...'. Drop the leading slash to avoid a double slash.
var armBackendBaseUrl = '${armAudience}${substring(providerAccountResourceId, 1)}'

var discoveryPolicyTemplate = '''<policies>
  <inbound>
    <base />
    <authentication-managed-identity resource="@@ARMAUD@@" />
    <rewrite-uri template="@@REWRITE@@" copy-unmatched-params="false" />
    <set-backend-service base-url="@@ARMBACKEND@@" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>'''

var listDeploymentsPolicy = replace(
  replace(
    replace(discoveryPolicyTemplate, '@@ARMAUD@@', armAudience),
    '@@REWRITE@@',
    '/deployments?api-version=${deploymentDiscoveryApiVersion}'
  ),
  '@@ARMBACKEND@@',
  armBackendBaseUrl
)

var getDeploymentPolicy = replace(
  replace(
    replace(discoveryPolicyTemplate, '@@ARMAUD@@', armAudience),
    '@@REWRITE@@',
    '/deployments/{deploymentName}?api-version=${deploymentDiscoveryApiVersion}'
  ),
  '@@ARMBACKEND@@',
  armBackendBaseUrl
)

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource inferenceApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: apiPath
  properties: {
    displayName: 'Model Gateway inference'
    path: apiPath
    protocols: [
      'https'
    ]
    // Require an APIM subscription key IN ADDITION to the Entra JWT (defense in depth).
    // Accept it on the 'api-key' header/query — the same name AOAI clients use, which is
    // what the Foundry connection sends via metadata.customHeaders.
    subscriptionRequired: subscriptionRequired
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
    serviceUrl: backendBaseUrl
  }
}

resource chatCompletionsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: inferenceApi
  name: 'chat-completions'
  properties: {
    displayName: 'Chat Completions'
    method: 'POST'
    urlTemplate: '/deployments/{deploymentName}/chat/completions'
    templateParameters: [
      {
        name: 'deploymentName'
        type: 'string'
        description: 'Model deployment name on the provider Foundry account'
        required: true
      }
    ]
    request: {
      queryParameters: [
        {
          name: 'api-version'
          type: 'string'
          required: false
        }
      ]
    }
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: inferenceApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: renderedPolicy
  }
  dependsOn: [
    chatCompletionsOperation
  ]
}

// -------------------- Dynamic discovery operations --------------------

resource listDeploymentsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: inferenceApi
  name: 'list-deployments'
  properties: {
    displayName: 'List Deployments'
    method: 'GET'
    urlTemplate: '/deployments'
    description: 'Dynamic discovery: list the provider account model deployments (ARM control plane).'
  }
}

resource listDeploymentsPolicyResource 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: listDeploymentsOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: listDeploymentsPolicy
  }
  dependsOn: [
    apiPolicy
  ]
}

resource getDeploymentOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: inferenceApi
  name: 'get-deployment-by-name'
  properties: {
    displayName: 'Get Deployment By Name'
    method: 'GET'
    urlTemplate: '/deployments/{deploymentName}'
    templateParameters: [
      {
        name: 'deploymentName'
        type: 'string'
        description: 'Model deployment name on the provider Foundry account'
        required: true
      }
    ]
    description: 'Dynamic discovery: get a single provider account model deployment (ARM control plane).'
  }
}

resource getDeploymentPolicyResource 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: getDeploymentOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: getDeploymentPolicy
  }
  dependsOn: [
    apiPolicy
  ]
}

// Managed subscription scoped to this API, with a caller-supplied primary key so the
// Foundry connection can present the same 'api-key'. Only created when a key is supplied.
resource apiSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = if (subscriptionRequired && !empty(apiSubscriptionKey)) {
  parent: apim
  name: '${apiPath}-subscription'
  properties: {
    displayName: 'Model Gateway inference subscription'
    scope: inferenceApi.id
    state: 'active'
    primaryKey: apiSubscriptionKey
  }
}

output apiName string = inferenceApi.name
output apiPath string = inferenceApi.properties.path
