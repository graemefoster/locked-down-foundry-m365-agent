/*
  Model-Gateway: Foundry project → APIM connection
  -------------------------------------------------
  Advertises the APIM model gateway to the PRIMARY Foundry project as an
  ApiManagement connection (like apim-connection.bicep), authenticated with the
  project's managed identity (ProjectManagedIdentity — keyless). Models are discovered
  dynamically at runtime (no static `models` array); agents reference the exposed model as
  '<connectionName>/<exposedModelName>'. Inference uses the model-in-body (deploymentInPath
  = false) v1 API surface — the APIM API forwards to the provider's /openai/v1 endpoint.

  Modelled on foundry-samples 01-connections/apim/modules/apim-connection-common.bicep.
*/

@description('Name of the primary AI Foundry (Cognitive Services) account')
param aiFoundryName string

@description('Name of the primary Foundry project')
param projectName string

@description('Name for the connection (this is the "apim-connection-name")')
param connectionName string

@description('APIM gateway URL, e.g. https://<apim>.azure-api.net')
param apimGatewayUrl string

@description('API path on APIM, e.g. inference')
param apiPath string

@description('Exposed model / deployment name, e.g. gpt-5.4-mini. Used only to build the agentModelReference output; models are discovered dynamically at runtime.')
param exposedModelName string

@description('Inference API version the gateway expects. For the Azure OpenAI v1 API surface use "preview".')
param inferenceAPIVersion string = 'preview'

@description('Optional APIM subscription key. When set, it is sent to APIM as the "api-key" header alongside the project MI JWT (defense in depth).')
@secure()
param apiKey string = ''

@description('Share the connection with all project users')
param isSharedToAll bool = true

var target = '${apimGatewayUrl}/${apiPath}'

// Dynamic model discovery: no static `models` array is advertised. Foundry discovers
// models at runtime by calling GET /deployments (list) and GET /deployments/{name}
// (get) on the APIM API, which proxies the provider account's ARM deployments. Because
// APIM exposes the default /deployments endpoints with AzureOpenAI-format responses, no
// `modelDiscovery` override is needed. (Static and dynamic discovery are mutually
// exclusive — omitting `models` triggers dynamic discovery via APIM defaults.)
var baseMetadata = {
  deploymentInPath: 'false'
  inferenceAPIVersion: inferenceAPIVersion
}

// The APIM subscription key is attached via the authConfig mechanism (authHeaderName +
// authHeaderFormat) with the key stored in credentials.key and substituted for the
// {api_key} placeholder. Unlike customHeaders (which Foundry applies to inference calls
// ONLY, and expects as a serialized JSON string — not the object shape used previously),
// authConfig headers are sent on ALL gateway calls INCLUDING model discovery. That is
// required here because the APIM API sets subscriptionRequired=true on every operation,
// so a discovery call without the key would 401 and no models would be found.
// (Reverse-engineered from a portal-created ApiManagement connection: the portal emits
// the flat authHeaderName/authHeaderFormat metadata keys.)
var metadata = empty(apiKey)
  ? baseMetadata
  : union(baseMetadata, {
      authHeaderName: 'api-key'
      authHeaderFormat: '{api_key}'
    })

// The project MI JWT is the primary credential (ProjectManagedIdentity — keyless). When an
// api-key is supplied it is stored here so the {api_key} placeholder above resolves to it.
var credentials = empty(apiKey) ? {} : { key: apiKey }

resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiFoundryName
}

resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  name: projectName
  parent: aiFoundry
}

resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2026-05-15-preview' = {
  name: connectionName
  parent: aiProject
  properties: {
    category: 'ApiManagement'
    target: target
    authType: 'ProjectManagedIdentity'
    audience: 'https://cognitiveservices.azure.com'
    isSharedToAll: isSharedToAll
    credentials: credentials
    metadata: metadata
  }
}

output connectionName string = connection.name
output connectionId string = connection.id
output target string = target
@description('The model reference an agent should use: <connectionName>/<exposedModelName>')
output agentModelReference string = '${connectionName}/${exposedModelName}'
