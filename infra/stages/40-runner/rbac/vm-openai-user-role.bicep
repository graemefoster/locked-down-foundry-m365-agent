/*
  VM -> Cognitive Services OpenAI User RBAC
  -----------------------------------------
  Grants the dev VM's system-assigned managed identity the "Cognitive Services OpenAI
  User" role on the AI Services (Foundry) account.

  WHY THIS IS NEEDED (separate from Foundry User):
    An agent evaluation workflow (using the microsoft/ai-agent-evals action) runs on the
    in-VNet self-hosted runner, authenticating as the
    VM MI. The AI-assisted quality evaluators (intent_resolution, task_adherence, coherence,
    fluency, relevance) use a JUDGE MODEL: they call the model deployment's inference API
    directly (POST .../openai/deployments/<name>/chat/completions). That is a Cognitive
    Services DATA action, NOT a management action, so it is NOT covered by:
      * Contributor (RG)  -> management-plane only, grants no `dataActions`; and
      * Foundry User (project) -> scopes the Agents API, not raw OpenAI inference.
    Without an inference data-plane role the judge calls fail with:
      401 PermissionDenied "Principal does not have access to API/Operation."
    Note this is why only SOME evaluators failed: the safety evaluators (e.g. violence) use
    the Azure AI content-safety (RAI) service, a different data plane, so they still passed.

    "Cognitive Services OpenAI User" grants the inference data actions
    (Microsoft.CognitiveServices/accounts/OpenAI/deployments/.../action) the judge model
    needs — the exact remedy the error message itself points to:
    https://learn.microsoft.com/azure/ai-services/openai/how-to/role-based-access-control

  Scoped to the account (not the subscription) and wired only when the runner is installed
  (installGithubRunner), matching the opt-in, bounded-blast-radius approach of the VM's
  Contributor and Key Vault Secrets User assignments.
*/

@description('Name of the AI Services (Foundry) account hosting the evaluation judge model deployment.')
param accountName string

@description('Principal ID of the VM system-assigned managed identity.')
param vmPrincipalId string

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

// Cognitive Services OpenAI User: 5e0bd9bd-7b93-4f28-af87-19fc36ad61bd
// (read + inference data actions on OpenAI deployments; no management/grant rights).
resource openAiUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  scope: subscription()
}

resource vmOpenAiUserOnAccount 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: account
  name: guid(account.id, vmPrincipalId, openAiUserRole.id)
  properties: {
    principalId: vmPrincipalId
    roleDefinitionId: openAiUserRole.id
    principalType: 'ServicePrincipal'
  }
}
