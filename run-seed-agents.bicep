/*
  Standalone seed-agents runner
  ─────────────────────────────
  Use this template to re-run agent seeding against an existing deployment
  without re-running all of main.bicep.

  Deploy with:
    az deployment group create \
      --resource-group <rg> \
      --template-file ./run-seed-agents.bicep \
      --parameters ./run-seed-agents.bicepparam
*/

@description('Azure region — must match the resource group.')
param location string

@description('Full Foundry project endpoint URL (accountEndpoint + api/projects/projectName/).')
param foundryProjectEndpoint string

@description('Name of the model deployment used to back the agents (e.g. gpt-4o).')
param modelDeploymentName string

@description('Name of the Windows VM in the Foundry spoke VNet that will run the script.')
param vmName string

@description('Principal ID of the VM system-assigned managed identity. Get it with: az vm identity show -g <rg> -n <vm> --query principalId -o tsv')
param vmPrincipalId string

@description('Name of the AI Services (Foundry) account.')
param accountName string

@description('Name of the Foundry project (child of the account).')
param projectName string

module seedAgents 'modules-network-secured/seed-agents-script.bicep' = {
  name: 'run-seed-agents'
  params: {
    location: location
    foundryProjectEndpoint: foundryProjectEndpoint
    modelDeploymentName: modelDeploymentName
    vmName: vmName
    vmPrincipalId: vmPrincipalId
    accountName: accountName
    projectName: projectName
  }
}
