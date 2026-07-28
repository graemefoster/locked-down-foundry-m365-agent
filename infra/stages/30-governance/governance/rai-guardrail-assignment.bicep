/*
  Strict RAI content-filter guardrail for Cognitive Services model deployments.

  Assigns the BUILT-IN initiative:
    "[Preview]: Guardrail for Cognitive Services Deployments"
    /providers/Microsoft.Authorization/policySetDefinitions/5207647b-3e83-4e28-b836-c382cb5e2a2e

  IMPORTANT: this initiative (and every member policy) is AUDIT-ONLY today
  (allowed effects are Audit / Disabled, mode = Microsoft.CognitiveServices.Data).
  It reports compliance for model deployments' Responsible AI (content filter)
  configuration -- it does NOT block create/update of a non-compliant deployment.

  The parameter values below are intentionally STRICT: every filter must be
  enabled AND blocking, harm categories must trip at Medium or High, and the RAI
  policy must run in synchronous (block-capable) Default mode. A deployment whose
  RAI policy relaxes any of these will report Non-compliant.
*/

targetScope = 'resourceGroup'

@description('Resource ID of the built-in guardrail initiative (policy set definition). Built-in initiatives live at TENANT scope (/providers/Microsoft.Authorization/policySetDefinitions/<guid>), so this uses tenantResourceId — subscriptionResourceId would fabricate a /subscriptions/<sub>/... ID that does not exist (PolicySetDefinitionNotFound).')
param policySetDefinitionId string = tenantResourceId('Microsoft.Authorization/policySetDefinitions', '5207647b-3e83-4e28-b836-c382cb5e2a2e')

@description('Version selector for the (preview) initiative.')
param definitionVersion string = '1.*.*-preview'

@description('Policy effect. The built-in only supports Audit or Disabled (it cannot block).')
@allowed([
  'Audit'
  'Disabled'
])
param effect string = 'Audit'

@description('Name (unique within the resource group) of the policy assignment.')
param assignmentName string = 'rai-guardrail-strict'

@description('Friendly display name of the policy assignment.')
param displayName string = 'RAI guardrail (strict, Audit) for Cognitive Services model deployments'

// Strict allowed-value sets. A single value = mandatory; two values would mean "either is fine".
var mustEnable = [ 'true' ]
var mustBlock = [ 'true' ]
var severities = [ 'Medium', 'High' ]

resource assignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: assignmentName
  properties: {
    displayName: displayName
    description: 'Mandates enabled + blocking content filtering (Medium/High) on every model deployment. Audit-only: reports Non-compliant, does not block.'
    policyDefinitionId: policySetDefinitionId
    definitionVersion: definitionVersion
    enforcementMode: 'Default'
    parameters: {
      effect: { value: effect }

      // ---- Sexual ----
      allowedSexualEnabledForPrompt: { value: mustEnable }
      allowedSexualBlockingForPrompt: { value: mustBlock }
      allowedSexualSeveritiesForPrompt: { value: severities }
      allowedSexualEnabledForCompletion: { value: mustEnable }
      allowedSexualBlockingForCompletion: { value: mustBlock }
      allowedSexualSeveritiesForCompletion: { value: severities }

      // ---- Hate ----
      allowedHateEnabledForPrompt: { value: mustEnable }
      allowedHateBlockingForPrompt: { value: mustBlock }
      allowedHateSeveritiesForPrompt: { value: severities }
      allowedHateEnabledForCompletion: { value: mustEnable }
      allowedHateBlockingForCompletion: { value: mustBlock }
      allowedHateSeveritiesForCompletion: { value: severities }

      // ---- Violence ----
      allowedViolenceEnabledForPrompt: { value: mustEnable }
      allowedViolenceBlockingForPrompt: { value: mustBlock }
      allowedViolenceSeveritiesForPrompt: { value: severities }
      allowedViolenceEnabledForCompletion: { value: mustEnable }
      allowedViolenceBlockingForCompletion: { value: mustBlock }
      allowedViolenceSeveritiesForCompletion: { value: severities }

      // ---- Self-harm ----
      allowedSelfharmEnabledForPrompt: { value: mustEnable }
      allowedSelfharmBlockingForPrompt: { value: mustBlock }
      allowedSelfharmSeveritiesForPrompt: { value: severities }
      allowedSelfharmEnabledForCompletion: { value: mustEnable }
      allowedSelfharmBlockingForCompletion: { value: mustBlock }
      allowedSelfharmSeveritiesForCompletion: { value: severities }

      // ---- Jailbreak (direct prompt attack) ----
      allowedJailbreakEnabledForPrompt: { value: mustEnable }
      allowedJailbreakBlockingForPrompt: { value: mustBlock }

      // ---- Profanity ----
      allowedProfanityEnabledForPrompt: { value: mustEnable }
      allowedProfanityBlockingForPrompt: { value: mustBlock }
      allowedProfanityEnabledForCompletion: { value: mustEnable }
      allowedProfanityBlockingForCompletion: { value: mustBlock }

      // ---- Protected material ----
      allowedProtectedMaterialCodeEnabledForCompletion: { value: mustEnable }
      allowedProtectedMaterialCodeBlockingForCompletion: { value: mustBlock }
      allowedProtectedMaterialTextEnabledForCompletion: { value: mustEnable }
      allowedProtectedMaterialTextBlockingForCompletion: { value: mustBlock }

      // ---- Indirect attack (XPIA) + Spotlighting defense ----
      allowedIndirectAttackEnabledForPrompt: { value: mustEnable }
      allowedIndirectAttackBlockingForPrompt: { value: mustBlock }
      allowedSpotlightingEnabledForPrompt: { value: mustEnable }
      allowedSpotlightingBlockingForPrompt: { value: mustBlock }

      // ---- Streaming / RAI mode: must be synchronous (block-capable) ----
      raiPolicyMode: { value: [ 'Default' ] }
    }
  }
}

@description('Resource ID of the created policy assignment.')
output assignmentId string = assignment.id

@description('Name of the created policy assignment.')
output assignmentName string = assignment.name
