/*
  Model-Gateway: APIM inference API + policy
  ------------------------------------------
  Defines the inference API on APIM and its policy. Auth posture: keyless MI. The
  Foundry connection authenticates with the project managed identity's Entra token
  (no APIM subscription key), so:

    * Platform: subscriptionRequired = false. A Foundry ApiManagement connection cannot
      present BOTH an MI token and an APIM subscription key, and the dynamic-discovery
      probe carries no key — so requiring one would 401 discovery and surface no models.
      The security boundary is the Entra JWT + xms_mirid pin + private networking instead.
    * Inbound (all operations that inherit <base/>): validate-azure-ad-token runs
      UNCONDITIONALLY — the caller MUST present a valid Entra token for the tenant +
      audience 'https://cognitiveservices.azure.com'.
    * required-claims/xms_mirid — when callerProjectResourceId is supplied, the
      token is pinned to the CALLING Foundry project's managed identity (the
      xms_mirid claim equals the project's ARM resource ID). This is the guide's
      correct way to lock the gateway to a specific project MI (a project MI does
      not expose an app/client ID in ARM). Because validation is unconditional, this
      pin is always enforced. An optional client-app pin (projectMiClientId) is also
      supported for callers that can supply one.
    * set-backend-service + authentication-managed-identity — APIM forwards to the
      provider Foundry's private OpenAI endpoint (over the private endpoint) and
      authenticates to it using its OWN managed identity.

  The discovery operations (GET /deployments, /deployments/{name}) intentionally do
  NOT inherit <base/> (see below): they are unauthenticated at the APIM edge (the runtime
  discovery probe carries neither the project JWT nor a subscription key) and are secured by
  the private network boundary + APIM's ARM managed identity to the control plane.

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

@description('Optional caller app/client ID to additionally restrict inbound callers (empty = do not pin on client-application-id)')
param projectMiClientId string = ''

@description('ARM resource ID of the CALLING Foundry project. When supplied, the inbound JWT is pinned via the xms_mirid required-claim to this project MI (guide-recommended). Empty = validate tenant + audience only.')
param callerProjectResourceId string = ''

@description('API version used for the ARM control-plane model-discovery calls (GET /deployments).')
param deploymentDiscoveryApiVersion string = '2023-05-01'

@description('Application Insights metric namespace for chat-completions token usage.')
param metricNamespace string = 'model-gateway-tokens'

var tenantId = subscription().tenantId

var clientAppRestriction = empty(projectMiClientId)
  ? ''
  : '<client-application-ids><application-id>@@CLIENTID@@</application-id></client-application-ids>'

// xms_mirid pins the token to the calling project's managed identity. Azure MSI tokens
// emit xms_mirid with the segment keyword 'resourcegroups' LOWERCASE while preserving the
// casing of user-supplied names, whereas ARM resource IDs use 'resourceGroups'. Under
// match="any" we therefore list: (1) the raw ARM ID, (2) the ARM ID with only the
// '/resourceGroups/' segment lowercased (the common MSI-token form, names preserved), and
// (3) a fully lowercased fallback — so the claim matches regardless of which form the
// token emits.
var callerIdResourceGroupsLowered = replace(callerProjectResourceId, '/resourceGroups/', '/resourcegroups/')
var requiredClaims = empty(callerProjectResourceId)
  ? ''
  : '<required-claims><claim name="xms_mirid" match="any"><value>@@PROJID@@</value><value>@@PROJID_RGLOWER@@</value><value>@@PROJID_LOWER@@</value></claim></required-claims>'

// APIM backend IDs. Both Foundry edges are expressed as first-class APIM `backend`
// entities (not hardwired base-urls) so tooling can discover the APIM -> provider edges;
// the policies reference them by ID.
var dataPlaneBackendId = 'model-gateway-openai'
var armBackendId = 'model-gateway-arm'

// NOTE: Bicep does NOT interpolate ${...} inside multi-line ('''...''') strings — the
// tokens would be emitted literally. So the template uses inert @@TOKEN@@ placeholders
// and replace() swaps in the resolved values (replace's arguments are single-line
// literals, so they are safe from interpolation too).
var policyTemplate = '''<policies>
  <inbound>
    <base />
    <validate-azure-ad-token tenant-id="@@TENANT@@" header-name="Authorization" output-token-variable-name="jwt" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized: token failed validation.">
      @@CLIENT_APPS@@
      <audiences>
        <audience>@@AUDIENCE@@</audience>
        <audience>@@AUDIENCE@@/</audience>
      </audiences>
      @@REQUIRED_CLAIMS@@
    </validate-azure-ad-token>
    <set-variable name="callerAppId" value="@(((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;azp&quot;, ((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;appid&quot;, string.Empty)).ToLowerInvariant())" />
    <llm-emit-token-metric namespace="@@METRIC_NAMESPACE@@">
      <dimension name="API ID" />
      <dimension name="Operation ID" />
      <dimension name="Backend ID" />
      <dimension name="CallerAppId" value="@((string)context.Variables[&quot;callerAppId&quot;])" />
    </llm-emit-token-metric>
    <set-backend-service backend-id="@@BACKENDID@@" />
    <authentication-managed-identity resource="@@AUDIENCE@@" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>'''

var clientAppRendered = replace(clientAppRestriction, '@@CLIENTID@@', projectMiClientId)

// Replace longest tokens first: '@@PROJID@@' is a substring of the other two
// placeholders, so replacing it first would corrupt the still-unreplaced
// '@@PROJID_RGLOWER@@' / '@@PROJID_LOWER@@' tokens.
var requiredClaimsRendered = replace(
  replace(
    replace(requiredClaims, '@@PROJID_RGLOWER@@', callerIdResourceGroupsLowered),
    '@@PROJID_LOWER@@',
    toLower(callerProjectResourceId)
  ),
  '@@PROJID@@',
  callerProjectResourceId
)

var renderedPolicy = replace(
  replace(
    replace(
      replace(
        replace(policyTemplate, '@@TENANT@@', tenantId),
        '@@CLIENT_APPS@@',
        clientAppRendered
      ),
      '@@REQUIRED_CLAIMS@@',
      requiredClaimsRendered
    ),
    '@@AUDIENCE@@',
    tokenAudience
  ),
  '@@BACKENDID@@',
  dataPlaneBackendId
)

var renderedPolicyWithMetricNamespace = replace(renderedPolicy, '@@METRIC_NAMESPACE@@', metricNamespace)

// -------------------- Dynamic model discovery --------------------
// Foundry discovers models at runtime by calling GET /deployments (list) and
// GET /deployments/{deploymentName} (get) on this API. Those calls are routed to
// the Azure Resource Manager CONTROL plane for the provider account (not the
// data-plane openai endpoint) because ARM returns the AzureOpenAI-format deployment
// list Foundry expects. Following the foundry-samples guide, these operation policies
// do NOT include <base/> — they intentionally bypass the API-level caller auth (the
// discovery probe may not carry the same subscription-key/JWT credentials) and only
// attach APIM's managed identity for the ARM control plane. The private endpoint /
// VNet is the network boundary for these operations.
var armAudience = environment().resourceManager
// environment().resourceManager ends with '/'; providerAccountResourceId starts with
// '/subscriptions/...'. Drop the leading slash to avoid a double slash.
var armBackendBaseUrl = '${armAudience}${substring(providerAccountResourceId, 1)}'

var discoveryPolicyTemplate = '''<policies>
  <inbound>
    <authentication-managed-identity resource="@@ARMAUD@@" />
    <rewrite-uri template="@@REWRITE@@" copy-unmatched-params="false" />
    <set-backend-service backend-id="@@ARMBACKENDID@@" />
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
  '@@ARMBACKENDID@@',
  armBackendId
)

var getDeploymentPolicy = replace(
  replace(
    replace(discoveryPolicyTemplate, '@@ARMAUD@@', armAudience),
    '@@REWRITE@@',
    '/deployments/{deploymentName}?api-version=${deploymentDiscoveryApiVersion}'
  ),
  '@@ARMBACKENDID@@',
  armBackendId
)

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

// First-class backends — the provider Foundry data-plane (OpenAI v1) and the ARM
// control-plane used for dynamic model discovery. Policies target these by ID.
resource dataPlaneBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: dataPlaneBackendId
  properties: {
    title: 'Provider Foundry (OpenAI v1)'
    description: 'Provider Foundry account OpenAI v1 surface (private endpoint). Chat completions forward here with APIM MI auth.'
    protocol: 'http'
    url: '${backendBaseUrl}/v1'
  }
}

resource armBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: armBackendId
  properties: {
    title: 'Provider Foundry (ARM control plane)'
    description: 'Azure Resource Manager deployments API for the provider account, backing dynamic model discovery (GET /deployments).'
    protocol: 'http'
    url: armBackendBaseUrl
  }
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
    // Keyless MI auth: subscriptionRequired=false. A Foundry ApiManagement connection
    // authenticates with the project MI's Entra token and cannot also present an APIM
    // subscription key, and the dynamic-discovery probe carries no key — so requiring one
    // would 401 discovery and surface no models. The Entra JWT + xms_mirid pin + private
    // network path are the security boundary. No serviceUrl: the chat operation routes to
    // the `dataPlaneBackend` backend by ID (model-in-body -> /openai/v1/chat/completions).
    subscriptionRequired: false
  }
}

resource chatCompletionsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: inferenceApi
  name: 'chat-completions'
  properties: {
    displayName: 'Chat Completions'
    method: 'POST'
    // Model-in-body (deploymentInPath=false): Foundry POSTs {"model":"<deployment>",...} to
    // {target}/chat/completions. This op inherits the API-level <base/> policy (JWT + xms_mirid
    // + set-backend-service to /openai/v1 + backend MI auth), forwarding to the provider's
    // /openai/v1/chat/completions endpoint. No deploymentName path parameter is used.
    urlTemplate: '/chat/completions'
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
    value: renderedPolicyWithMetricNamespace
  }
  dependsOn: [
    chatCompletionsOperation
    dataPlaneBackend
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
    armBackend
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
    armBackend
  ]
}

output apiName string = inferenceApi.name
output apiPath string = inferenceApi.properties.path
