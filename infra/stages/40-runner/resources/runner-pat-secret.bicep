/*
  Runner PAT -> Key Vault secret (control-plane write).
  -----------------------------------------------------
  Writes the fine-grained GitHub PAT into Key Vault via ARM. This is a
  MANAGEMENT-PLANE operation, so it succeeds even though the vault has
  publicNetworkAccess=Disabled + networkAcls Deny (the firewall only governs the
  DATA plane) — no in-VNet seeding, temp roles, or run-command needed.

  Deployed only when a PAT value is supplied (see the conditional in main.bicep),
  so clearing GITHUB_RUNNER_PAT later leaves the existing secret untouched
  (ARM incremental mode never deletes resources absent from the template).
*/

@description('Key Vault (DNS) name to write the runner PAT into.')
param keyVaultName string

@description('Name of the secret to create/update.')
param secretName string

@description('The fine-grained PAT value (Administration: read & write).')
@secure()
param patValue string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource runnerPatSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: secretName
  properties: {
    value: patValue
  }
}
