/*
Common module for creating ModelGateway connections to Azure AI Foundry projects.
This module handles the core connection logic and can be reused across different ModelGateway connection samples.
ModelGateway connections support ApiKey and Oauth2.0 client credentials authentication.
*/

// Project resource parameters
//        <set-backend-service base-url="https://management.azure.com/subscriptions/b045f4eb-724b-4361-80ff-2a0ff999a996/resourceGroups/PublicFoundry/providers/Microsoft.CognitiveServices/accounts/grfpublicfoundryaueast" />

var projectResourceId string = '/subscriptions/b045f4eb-724b-4361-80ff-2a0ff999a996/resourceGroups/private-ai-foundry-firewall-a365-08/providers/Microsoft.CognitiveServices/accounts/aiserviceslw4v/projects/projectlw4v'
param connectionName string = 'byopaim'

// ModelGateway target configuration
param targetUrl string = 'https://grfstandardv2test.azure-api.net/grfaoai/openai'

// Connection configuration (ModelGateway supports ApiKey and OAuth2)
@allowed(['ApiKey', 'OAuth2'])
param authType string = 'ApiKey'
param isSharedToAll bool = false

// API key for the ModelGateway endpoint (required for ApiKey auth)
var apiKey string = 'b5219565bbf144b5a04491a6913caed7'

// Extract project information from resource ID
var aiFoundryName = split(projectResourceId, '/')[8]
var projectName = split(projectResourceId, '/')[10]

// Reference the AI Foundry account
resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiFoundryName
  scope: resourceGroup()
}

// Reference the project within the AI Foundry account
resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  name: projectName
  parent: aiFoundry
}

// Create the ModelGateway connection with ApiKey authentication
resource connectionApiKey 'Microsoft.CognitiveServices/accounts/projects/connections@2026-03-01' = if (authType == 'ApiKey') {
  name: connectionName
  parent: aiProject
  properties: {
    category: 'ApiManagement'
    target: targetUrl
    authType: 'ProjectManagedIdentity'
    audience: 'https://cognitiveservices.azure.com'
    isSharedToAll: isSharedToAll
    credentials: {
      key: apiKey
      keys: {
        'x-graeme-was-here': 'true'
        'x-second-test': 'my-test'
        'artifact-id': apiKey
      }
    }
    metadata: {
      deploymentAPIVersion: '2024-10-01'
      deploymentInPath: 'true'
      inferenceAPIVersion: '2025-03-01-preview'
      customHeaders: {
        value: {
          'x-graeme-was-here': 'true'
          'x-second-test': 'my-test'
          'api-key': apiKey
        }
      }
    }
  }
}

// Outputs
output targetUrl string = targetUrl
output authType string = authType
