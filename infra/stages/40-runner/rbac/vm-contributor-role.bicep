/*
  VM -> Contributor (resource group) RBAC
  ---------------------------------------
  Grants the dev VM's system-assigned managed identity the Contributor role over the
  resource group, so the self-hosted GitHub Actions runner (which runs AS the VM MI)
  can perform control-plane work for representative end-to-end deployments — notably
  creating the Azure Bot Service used by the Teams / M365 publish flow — directly from
  a gated workflow, instead of that ARM work only ever running host-side.

  Only wired when the runner is being installed (installGithubRunner). This is a
  deliberate, opt-in privilege expansion of the otherwise locked-down VM: enabling the
  runner turns the VM into a CI worker, and Contributor lets its gated (Posture A)
  workflows manage resources in this resource group. It is scoped to the resource group
  only — not the subscription — to bound the blast radius.
*/

@description('Principal ID of the VM system-assigned managed identity.')
param vmPrincipalId string

// Contributor: b24988ac-6180-42a0-ab88-20f7382dd24c (manage all resources, no RBAC/grant).
resource contributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  scope: subscription()
}

resource vmContributorOnRg 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: resourceGroup()
  name: guid(resourceGroup().id, vmPrincipalId, contributorRole.id)
  properties: {
    principalId: vmPrincipalId
    roleDefinitionId: contributorRole.id
    principalType: 'ServicePrincipal'
  }
}
