/*
  VM -> Foundry User RBAC
  -----------------------
  Grants the runner VM's system-assigned managed identity the Foundry User role on the
  Foundry project. Agent deploys now run from the in-VNet self-hosted GitHub Actions runner
  (per-agent .github/workflows/deploy-*-agent.yml -> scripts/deploy-*-agent.ps1), executing natively
  on this VM; that script acquires a managed-identity token via IMDS and calls the Agents API, so
  this role assignment must exist before the deploy workflow runs.
*/

@description('Name of the AI Services (Foundry) account.')
param accountName string

@description('Name of the Foundry project.')
param projectName string

@description('Principal ID of the VM system-assigned managed identity.')
param vmPrincipalId string

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: account
  name: projectName
}

// Foundry User role — required for the Agents API (2025-11-15-preview).
// Role GUID: 53ca6127-db72-4b80-b1b0-d745d6d5456d
resource foundryUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '53ca6127-db72-4b80-b1b0-d745d6d5456d'
  scope: subscription()
}

resource vmFoundryUserOnProject 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: project
  name: guid(project.id, vmPrincipalId, foundryUserRole.id)
  properties: {
    principalId: vmPrincipalId
    roleDefinitionId: foundryUserRole.id
    principalType: 'ServicePrincipal'
  }
}
