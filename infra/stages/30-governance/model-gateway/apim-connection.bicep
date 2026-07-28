/*
  Model-Gateway: Foundry project → APIM connection
  -------------------------------------------------
  Advertises the APIM model gateway to the PRIMARY Foundry project as an
  ApiManagement connection (like apim-connection.bicep), authenticated with the
  project's managed identity (ProjectManagedIdentity — keyless). The hosted-agent runtime
  reaches APIM directly and references the model as '<connectionName>/<exposedModelName>';
  it does NOT rely on the Foundry portal's model-discovery list (which can show "no models"
  for a private-only APIM — that is cosmetic, see the modelDiscovery note below). Agents
  reference the exposed model as
  '<connectionName>/<exposedModelName>'. Inference uses the model-in-body (deploymentInPath
  = false) v1 API surface — the APIM API forwards to the provider's /openai/v1 endpoint.

  Auth is keyless: the connection sends ONLY the project MI's Entra token (authType
  ProjectManagedIdentity, credentials {}). No APIM subscription key ("api-key") is sent —
  a Foundry connection cannot present both an MI token AND a subscription key, so the APIM
  inference API must have subscriptionRequired=false (see apim-api-policy.bicep). The gateway
  is secured by the unconditional Entra JWT + xms_mirid project pin + private networking.

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

@description('APIM-relative endpoint Foundry calls to list models (enables dynamic discovery).')
param listModelsEndpoint string = '/deployments'

@description('APIM-relative endpoint Foundry calls to get a single model (enables dynamic discovery).')
param getModelEndpoint string = '/deployments/{deploymentName}'

@description('Provider format Foundry expects from the discovery endpoints.')
param deploymentProvider string = 'AzureOpenAI'

@description('Share the connection with all project users')
param isSharedToAll bool = true

var target = '${apimGatewayUrl}/${apiPath}'

// Dynamic model discovery config. `modelDiscovery` is the documented metadata for exposing
// the APIM list/get endpoints (serialized as a JSON string; see foundry-samples
// connection-apim.bicep, which requires either `modelDiscovery` OR a static `models` array).
// Static and dynamic discovery are mutually exclusive — do not also set `models`.
//
// NOTE (learned the hard way): the Foundry PORTAL's model-discovery UI runs from a
// control-plane origin that cannot reach a private-only APIM, so it may show "no models"
// regardless of this metadata. That is cosmetic. The hosted-agent RUNTIME does NOT depend on
// portal discovery — it reaches APIM directly and references the model as
// '<connectionName>/<exposedModelName>'. The real prerequisite for the runtime to work is the
// NETWORK PATH: the agent subnet must be allowed outbound to the APIM private endpoint (see
// the Allow-ModelGatewayApim-Outbound NSG rule in foundry-spoke-vnet.bicep). If an agent
// can't reach its model, check the NSG/firewall to the APIM PE first, not this metadata.
//
// Keyless auth: no authConfig / api-key is set — the connection authenticates with the
// project MI token only (see file header), and the APIM inference API must be
// subscriptionRequired=false so any keyless probe (which carries no subscription key) is
// not rejected.
var metadata = {
  deploymentInPath: 'false'
  inferenceAPIVersion: inferenceAPIVersion
  modelDiscovery: string({
    listModelsEndpoint: listModelsEndpoint
    getModelEndpoint: getModelEndpoint
    deploymentProvider: deploymentProvider
  })
}

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
    credentials: {}
    metadata: metadata
  }
}

output connectionName string = connection.name
output connectionId string = connection.id
output target string = target
@description('The model reference an agent should use: <connectionName>/<exposedModelName>')
output agentModelReference string = '${connectionName}/${exposedModelName}'
