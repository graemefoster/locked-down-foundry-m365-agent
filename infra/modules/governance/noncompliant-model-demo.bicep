/*
  DEMO: a deliberately NON-COMPLIANT model deployment.

  Creates a custom Responsible AI (content filter) policy that violates the strict
  guardrail assignment in several ways, then a model deployment that uses it:
    - mode = Asynchronous_filter   -> violates raiPolicyMode ['Default']
    - Hate filter disabled          -> violates allowedHate*Enabled ['true']
    - Violence filter non-blocking  -> violates allowedViolence*Blocking ['true']
    - Jailbreak detection disabled  -> violates allowedJailbreakEnabledForPrompt ['true']

  After deployment, Azure Policy will report this deployment as Non-compliant against
  the guardrail initiative. Because the built-in is Audit-only, the deployment is
  still created successfully (nothing is blocked) -- the point is to see it flagged.

  Gated behind a parameter in main.bicep; off by default.
*/

targetScope = 'resourceGroup'

@description('Name of the existing Cognitive Services / AI Services account to attach the demo deployment to.')
param accountName string

@description('Name of the (weak) custom RAI content-filter policy.')
param raiPolicyName string = 'weak-demo-policy'

@description('Base RAI policy the custom policy derives from.')
param basePolicyName string = 'Microsoft.DefaultV2'

@description('Name of the deliberately non-compliant model deployment.')
param deploymentName string = 'noncompliant-demo'

@description('Model to deploy for the demo (reuse the same model family as the primary deployment).')
param modelName string

@description('Model format, e.g. OpenAI.')
param modelFormat string

@description('Model version.')
param modelVersion string

@description('Deployment SKU name, e.g. GlobalStandard.')
param modelSkuName string

@description('Deployment capacity. Kept small for a throwaway demo.')
param modelCapacity int = 1

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource weakRaiPolicy 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = {
  parent: account
  name: raiPolicyName
  properties: {
    basePolicyName: basePolicyName
    mode: 'Asynchronous_filter'
    contentFilters: [
      {
        name: 'Hate'
        enabled: false
        blocking: false
        severityThreshold: 'High'
        source: 'Prompt'
      }
      {
        name: 'Hate'
        enabled: false
        blocking: false
        severityThreshold: 'High'
        source: 'Completion'
      }
      {
        name: 'Violence'
        enabled: true
        blocking: false
        severityThreshold: 'High'
        source: 'Prompt'
      }
      {
        name: 'Violence'
        enabled: true
        blocking: false
        severityThreshold: 'High'
        source: 'Completion'
      }
      {
        name: 'Jailbreak'
        enabled: false
        blocking: false
        source: 'Prompt'
      }
    ]
  }
}

#disable-next-line BCP081
resource weakDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: account
  name: deploymentName
  sku: {
    name: modelSkuName
    capacity: modelCapacity
  }
  properties: {
    model: {
      name: modelName
      format: modelFormat
      version: modelVersion
    }
    raiPolicyName: weakRaiPolicy.name
  }
}

@description('Name of the non-compliant demo deployment.')
output deploymentName string = weakDeployment.name

@description('Name of the weak RAI policy.')
output raiPolicyName string = weakRaiPolicy.name
