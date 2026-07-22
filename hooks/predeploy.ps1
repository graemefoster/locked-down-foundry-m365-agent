<#
  azd predeploy hook: seed Foundry agents
  ---------------------------------------
  Runs on the azd host (laptop / CI). The Foundry endpoint is private, so this hook cannot
  call the Agents API directly. Instead it uses `az vm run-command` to execute
  scripts/seed-agents.ps1 ON the locked-down VM inside the VNet, which can reach the private
  endpoint. Agent definitions live in scripts/seed-agents.ps1.

  Iterate on agents without a provision pass:
      azd hooks run predeploy      # runs this hook directly
      azd deploy                   # also runs it (once a service is defined in azure.yaml)

  Required env vars (surfaced by azd from the Bicep outputs):
      AZURE_RESOURCE_GROUP, SEED_AGENTS_VM_NAME, AZURE_AI_PROJECT_ENDPOINT,
      AZURE_AI_MODEL_DEPLOYMENT_NAME, SEED_ENABLE_SECOND_AGENT, SEED_SECOND_AGENT_MODEL

  Caller RBAC: permission to invoke VM run-commands
  (Microsoft.Compute/virtualMachines/runCommands/*), e.g. Virtual Machine Contributor on the
  VM/resource group.
#>
$ErrorActionPreference = 'Stop'

function Get-RequiredEnv {
  param([string]$Name)
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "[predeploy] Required environment variable '$Name' is not set. Run 'azd provision' first so the Bicep outputs are available."
  }
  return $value
}

$resourceGroup   = Get-RequiredEnv 'AZURE_RESOURCE_GROUP'
$vmName          = Get-RequiredEnv 'SEED_AGENTS_VM_NAME'
$projectEndpoint = Get-RequiredEnv 'AZURE_AI_PROJECT_ENDPOINT'
$modelName       = Get-RequiredEnv 'AZURE_AI_MODEL_DEPLOYMENT_NAME'
$enableSecond    = [Environment]::GetEnvironmentVariable('SEED_ENABLE_SECOND_AGENT')
$secondModel     = [Environment]::GetEnvironmentVariable('SEED_SECOND_AGENT_MODEL')
if ([string]::IsNullOrWhiteSpace($enableSecond)) { $enableSecond = 'false' }
if ($null -eq $secondModel) { $secondModel = '' }

# azd env values can be JSON-quoted booleans/strings; normalise to what the script expects.
$enableSecond = $enableSecond.Trim('"').ToLowerInvariant()

$seedScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/seed-agents.ps1'
if (-not (Test-Path $seedScript)) {
  throw "[predeploy] Seed script not found at '$seedScript'."
}

Write-Host "[predeploy] Seeding agents on VM '$vmName' (resource group '$resourceGroup')..."
Write-Host "[predeploy] Foundry endpoint: $projectEndpoint"

$azArgs = @(
  'vm', 'run-command', 'invoke',
  '--command-id', 'RunPowerShellScript',
  '--name', $vmName,
  '--resource-group', $resourceGroup,
  '--scripts', "@$seedScript",
  '--parameters',
  "FoundryProjectEndpoint=$projectEndpoint",
  "ModelDeploymentName=$modelName",
  "EnableSecondAgent=$enableSecond",
  "SecondAgentModel=$secondModel",
  '--output', 'json'
)

$raw = az @azArgs
if ($LASTEXITCODE -ne 0) {
  Write-Host $raw
  throw "[predeploy] 'az vm run-command invoke' failed with exit code $LASTEXITCODE."
}

$result = $raw | ConvertFrom-Json
$message = ($result.value | ForEach-Object { $_.message }) -join "`n"

Write-Host '----- seed-agents output (from VM) -----'
Write-Host $message
Write-Host '----------------------------------------'

# The on-VM script has $ErrorActionPreference='Stop' and prints '[seed-agents] Done.' only on
# success. az invoke returns exit 0 even when the remote script throws, so gate on the marker.
if ($message -notmatch '\[seed-agents\] Done\.') {
  throw '[predeploy] Agent seeding did not complete successfully (missing completion marker). See VM output above.'
}

Write-Host '[predeploy] Agent seeding complete.'
