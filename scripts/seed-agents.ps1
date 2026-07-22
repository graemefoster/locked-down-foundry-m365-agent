<#
  Seed Foundry Agents (runs ON the private VM)
  --------------------------------------------
  Executed on the locked-down Windows VM (inside the private VNet) by the azd `predeploy`
  hook (hooks/predeploy.ps1) via `az vm run-command`. The VM is the only host that can reach
  the Foundry private endpoint, so the seeding logic must run here.

  It acquires a managed-identity token via IMDS and calls the Agents REST API. It is
  idempotent: existing agents (matched by name) are skipped, so re-running is safe.

  Edit the $agentsToCreate array below to change which agents get seeded.
#>
param(
  [Parameter(Mandatory = $true)]  [string]$FoundryProjectEndpoint,
  [Parameter(Mandatory = $true)]  [string]$ModelDeploymentName,
  [Parameter(Mandatory = $false)] [string]$EnableSecondAgent = 'false',
  [Parameter(Mandatory = $false)] [string]$SecondAgentModel = ''
)
$ErrorActionPreference = 'Stop'

function Get-FoundryToken {
  $response = Invoke-RestMethod `
    -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fai.azure.com%2F' `
    -Headers @{ Metadata = 'true' } `
    -Method Get
  return $response.access_token
}

function Get-ExistingAgents {
  param([string]$Token)
  $response = Invoke-RestMethod `
    -Method Get `
    -Uri "$FoundryProjectEndpoint/agents?api-version=2025-11-15-preview" `
    -Headers @{ Authorization = "Bearer $Token" }
  return $response.data
}

function New-Agent {
  param([string]$Token, [string]$Name, [string]$Instructions, [string]$Model)
  $body = @{
    name        = $Name
    description = $Name
    definition  = @{
      kind         = 'prompt'
      model        = $Model
      instructions = $Instructions
    }
  } | ConvertTo-Json -Depth 10 -Compress

  $response = Invoke-RestMethod `
    -Method Post `
    -Uri "$FoundryProjectEndpoint/agents?api-version=2025-11-15-preview" `
    -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
    -Body $body
  return $response.id
}

Write-Host '[seed-agents] Starting...'
Write-Host "[seed-agents] Endpoint: $FoundryProjectEndpoint"

# Normalise: strip trailing slash so /agents never becomes //agents
$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')

$token = Get-FoundryToken
Write-Host '[seed-agents] Token acquired.'

$existing = Get-ExistingAgents -Token $token
$existingNames = $existing | ForEach-Object { $_.name }

# --- Agent definitions ---
# Add more entries here to seed additional agents.
$agentsToCreate = @(
  @{
    Name         = 'hello-world-agent'
    Model        = $ModelDeploymentName
    Instructions = 'You are a helpful AI assistant. Answer questions clearly and concisely.'
  }
)

# Optional second agent routed through the model-gateway (APIM) connection.
# Its model is the "<apim-connection-name>/<exposed-model-name>" reference.
if ($EnableSecondAgent -eq 'true' -and -not [string]::IsNullOrWhiteSpace($SecondAgentModel)) {
  $agentsToCreate += @{
    Name         = 'gateway-model-agent'
    Model        = $SecondAgentModel
    Instructions = 'You are a helpful AI assistant served through the enterprise model gateway. Answer questions clearly and concisely.'
  }
  Write-Host "[seed-agents] Second (gateway) agent enabled with model '$SecondAgentModel'."
}

foreach ($agentDef in $agentsToCreate) {
  if ($existingNames -contains $agentDef.Name) {
    Write-Host "[seed-agents] Agent '$($agentDef.Name)' already exists - skipping."
  }
  else {
    $id = New-Agent -Token $token -Name $agentDef.Name -Instructions $agentDef.Instructions -Model $agentDef.Model
    Write-Host "[seed-agents] Created '$($agentDef.Name)' -> $id"
  }
}

Write-Host '[seed-agents] Done.'
