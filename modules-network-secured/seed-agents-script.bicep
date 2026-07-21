/*
  Seed Foundry Agents via Windows VM Run Command
  -----------------------------------------------
  Runs a PowerShell script on the already-deployed Windows VM (which is inside the
  private VNet and can reach the Foundry private endpoint) to call the Agents REST
  API and provision the initial agent(s).

  This avoids the ACI/Deployment Script approach, which is unreliable in locked-down
  VNets due to RBAC propagation races and ACI container provisioning timeouts.

  The VM's system-assigned managed identity is granted Azure AI Developer on the
  Foundry project so the script can acquire a token via IMDS and call the API.

  Prerequisites:
    - VM must have a system-assigned identity (vm.bicep sets this).
    - Capability host and all post-caphost RBAC must be provisioned first.
    - Private endpoint DNS must be resolvable from the VM subnet.
*/

@description('Azure region for all resources.')
param location string

@description('Full Foundry project endpoint URL, e.g. https://ACCOUNT.services.ai.azure.com/api/projects/PROJECT/')
param foundryProjectEndpoint string

@description('Name of the model deployment to assign to the seeded agent.')
param modelDeploymentName string

@description('Name of the Windows VM that will execute the seeding script.')
param vmName string

@description('Principal ID of the VM system-assigned managed identity.')
param vmPrincipalId string

@description('Name of the AI Services (Foundry) account.')
param accountName string

@description('Name of the Foundry project.')
param projectName string

@description('Seed a second agent that uses the model-gateway (APIM) connection model reference.')
param enableSecondAgent bool = false

@description('Model reference for the second agent, e.g. "<apim-connection-name>/gpt-5.4-mini".')
param secondAgentModel string = ''

// ── Existing resources ───────────────────────────────────────────────────────

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: account
  name: projectName
}

resource vm 'Microsoft.Compute/virtualMachines@2022-03-01' existing = {
  name: vmName
}

// ── RBAC: Foundry User on the project ────────────────────────────────────────
// Required for the new Agents API (2025-11-15-preview).
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

// ── VM Run Command: seed agents ──────────────────────────────────────────────
// Runs PowerShell on the Windows VM. The VM is inside the private VNet and
// resolves the Foundry private endpoint via the hub DNS resolver.
// IMDS (169.254.169.254) provides the managed-identity token — no firewall needed.
//
// The script is idempotent: it lists existing agents first and skips creation
// if an agent with the same name already exists.
resource seedAgentsRunCommand 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'seed-agents'
  location: location
  parent: vm
  properties: {
    asyncExecution: false
    timeoutInSeconds: 300
    parameters: [
      { name: 'FoundryProjectEndpoint', value: foundryProjectEndpoint }
      { name: 'ModelDeploymentName',    value: modelDeploymentName    }
      { name: 'EnableSecondAgent',      value: string(enableSecondAgent) }
      { name: 'SecondAgentModel',       value: secondAgentModel       }
    ]
    source: {
      script: '''
param(
  [string]$FoundryProjectEndpoint,
  [string]$ModelDeploymentName,
  [string]$EnableSecondAgent,
  [string]$SecondAgentModel
)
$ErrorActionPreference = "Stop"

function Get-FoundryToken {
  $response = Invoke-RestMethod `
    -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fai.azure.com%2F" `
    -Headers @{ Metadata = "true" } `
    -Method Get
  return $response.access_token
}

function Get-ExistingAgents {
  param([string]$Token)
  $response = Invoke-RestMethod `
    -Method Get `
    -Uri "${FoundryProjectEndpoint}/agents?api-version=2025-11-15-preview" `
    -Headers @{ Authorization = "Bearer $Token" }
  return $response.value
}

function New-Agent {
  param([string]$Token, [string]$Name, [string]$Instructions, [string]$Model)
  $body = @{
    name        = $Name
    description = $Name
    definition  = @{
      kind         = "prompt"
      model        = $Model
      instructions = $Instructions
    }
  } | ConvertTo-Json -Depth 10 -Compress

  $response = Invoke-RestMethod `
    -Method Post `
    -Uri "${FoundryProjectEndpoint}/agents?api-version=2025-11-15-preview" `
    -Headers @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" } `
    -Body $body
  return $response.id
}

Write-Host "[seed-agents] Starting..."
Write-Host "[seed-agents] Endpoint: $FoundryProjectEndpoint"

# Normalise: strip trailing slash so /agents never becomes //agents
$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')

$token = Get-FoundryToken
Write-Host "[seed-agents] Token acquired."

$existing = Get-ExistingAgents -Token $token
$existingNames = $existing | ForEach-Object { $_.name }

# --- Agent definitions ---
# Add more entries here to seed additional agents.
$agentsToCreate = @(
  @{
    Name         = "hello-world-agent"
    Model        = $ModelDeploymentName
    Instructions = "You are a helpful AI assistant. Answer questions clearly and concisely."
  }
)

# Optional second agent routed through the model-gateway (APIM) connection.
# Its model is the "<apim-connection-name>/<exposed-model-name>" reference.
if ($EnableSecondAgent -eq "true" -and -not [string]::IsNullOrWhiteSpace($SecondAgentModel)) {
  $agentsToCreate += @{
    Name         = "gateway-model-agent"
    Model        = $SecondAgentModel
    Instructions = "You are a helpful AI assistant served through the enterprise model gateway. Answer questions clearly and concisely."
  }
  Write-Host "[seed-agents] Second (gateway) agent enabled with model '$SecondAgentModel'."
}

foreach ($agentDef in $agentsToCreate) {
  if ($existingNames -contains $agentDef.Name) {
    Write-Host "[seed-agents] Agent '$($agentDef.Name)' already exists - skipping."
  } else {
    $id = New-Agent -Token $token -Name $agentDef.Name -Instructions $agentDef.Instructions -Model $agentDef.Model
    Write-Host "[seed-agents] Created '$($agentDef.Name)' -> $id"
  }
}

Write-Host "[seed-agents] Done."
      '''
    }
  }
  dependsOn: [vmFoundryUserOnProject]
}
