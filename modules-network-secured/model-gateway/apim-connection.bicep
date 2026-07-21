/*
  Model-Gateway: Foundry project → APIM connection
  -------------------------------------------------
  Advertises the APIM model gateway to the PRIMARY Foundry project as an
  ApiManagement connection (like apim-connection.bicep), authenticated with the
  project's managed identity (ProjectManagedIdentity — keyless). The exposed model
  is advertised via the static-models metadata; agents reference it as
  '<connectionName>/<exposedModelName>'.

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

@description('Exposed model / deployment name, e.g. gpt-5.4-mini')
param exposedModelName string

@description('Model format for the advertised model')
param exposedModelFormat string = 'OpenAI'

@description('Model version for the advertised model')
param exposedModelVersion string

@description('Inference API version the gateway expects')
param inferenceAPIVersion string = '2025-03-01-preview'

@description('Optional APIM subscription key. When set, it is sent to APIM as the "api-key" header alongside the project MI JWT (defense in depth).')
@secure()
param apiKey string = ''

@description('Share the connection with all project users')
param isSharedToAll bool = true

var target = '${apimGatewayUrl}/${apiPath}'

var staticModels = [
  {
    name: exposedModelName
    properties: {
      model: {
        name: exposedModelName
        version: exposedModelVersion
        format: exposedModelFormat
      }
    }
  }
]

// Base metadata always advertises the exposed model. When an api-key is supplied,
// also send it as the 'api-key' custom header on every inference call — APIM enforces
// this subscription key IN ADDITION to validating the project MI's Entra JWT.
var baseMetadata = {
  deploymentInPath: 'true'
  inferenceAPIVersion: inferenceAPIVersion
  models: string(staticModels)
}

var metadata = empty(apiKey)
  ? baseMetadata
  : union(baseMetadata, {
      customHeaders: {
        value: {
          'api-key': apiKey
        }
      }
    })

// Keyless (Entra) auth. When an api-key is supplied it is ALSO stored so the gateway
// can present it — the JWT remains the primary credential (ProjectManagedIdentity).
var credentials = empty(apiKey) ? {} : { key: apiKey }

resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiFoundryName
}

resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  name: projectName
  parent: aiFoundry
}

resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
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
