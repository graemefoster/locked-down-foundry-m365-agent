<#
  azd predown hook: delete Foundry capability hosts before teardown
  -----------------------------------------------------------------
  A Foundry (Cognitive Services) account/project with an Agents capability host cannot be
  deleted cleanly while the capability host still exists - `azd down` will hang or fail on the
  account. This hook runs BEFORE azd deletes any resources, enumerates the capability hosts on
  the project (and account, to catch any auto-created one), and deletes each.

  Runs on the azd host (laptop / CI). Capability-host management is a control-plane (ARM)
  operation, so - unlike the private data-plane Agents API used by predeploy - it does NOT need
  the in-VNet VM.

  Best-effort by design: if the account/project is already gone or its names can't be resolved,
  the hook warns and lets azd proceed. It only fails the teardown if an actual capability-host
  delete fails (that would block Foundry deletion anyway, so surfacing it early is clearer).

  Required env vars (surfaced by azd from the Bicep outputs; run `azd env refresh` if missing):
      AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP, AZURE_AI_ACCOUNT_NAME, AZURE_AI_PROJECT_NAME

  Caller RBAC: permission to delete capability hosts
  (Microsoft.CognitiveServices/accounts/.../capabilityHosts/delete), e.g. Cognitive Services
  Contributor on the account/resource group.

  Requires: the `az` CLI, signed in (`az login`). No Az PowerShell modules are needed.
#>
$ErrorActionPreference = 'Stop'

$apiVersion = '2025-04-01-preview'

function Get-OptionalEnv {
  param([string]$Name)
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) { return $null }
  return $value.Trim().Trim('"')
}

$subscriptionId = Get-OptionalEnv 'AZURE_SUBSCRIPTION_ID'
$resourceGroup  = Get-OptionalEnv 'AZURE_RESOURCE_GROUP'
$accountName    = Get-OptionalEnv 'AZURE_AI_ACCOUNT_NAME'
$projectName    = Get-OptionalEnv 'AZURE_AI_PROJECT_NAME'

# Subscription can also be discovered from the current az CLI account.
if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
  $subFromCli = az account show --query id --output tsv 2>$null
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($subFromCli)) {
    $subscriptionId = $subFromCli.Trim()
  }
}

# Best-effort gate: if we truly can't act (no subscription/RG) or Foundry was never
# provisioned (no account/project names at all), skip and let azd proceed with teardown.
if ([string]::IsNullOrWhiteSpace($subscriptionId) -or [string]::IsNullOrWhiteSpace($resourceGroup)) {
  Write-Warning "[predown] AZURE_SUBSCRIPTION_ID / AZURE_RESOURCE_GROUP not set (run 'azd env refresh' to repopulate outputs). Skipping capability-host cleanup and letting azd proceed."
  exit 0
}

$hasAccount = -not [string]::IsNullOrWhiteSpace($accountName)
$hasProject = -not [string]::IsNullOrWhiteSpace($projectName)

if (-not $hasAccount -and -not $hasProject) {
  Write-Warning "[predown] No Foundry account/project names available (run 'azd env refresh'). Assuming Foundry is not provisioned; skipping capability-host cleanup."
  exit 0
}

# The blocking capability host is created at PROJECT scope, so we MUST know the project name.
if (-not $hasProject) {
  throw "[predown] AZURE_AI_ACCOUNT_NAME is set but AZURE_AI_PROJECT_NAME is missing. Cannot delete the project-scope capability host. Run 'azd env refresh' and retry 'azd down'."
}
if (-not $hasAccount) {
  throw "[predown] AZURE_AI_PROJECT_NAME is set but AZURE_AI_ACCOUNT_NAME is missing. Cannot build the capability-host resource path. Run 'azd env refresh' and retry 'azd down'."
}

$basePath = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.CognitiveServices/accounts/$accountName"

# Invokes an ARM management REST call via the az CLI. Returns a normalised object with
# .StatusCode and .Content so the callers keep their existing status/JSON handling. stdout
# (the JSON body) and stderr (az errors) are captured separately so a success-with-warning
# never pollutes the parsed body.
function Invoke-ArmRest {
  param([string]$Method, [string]$Url)
  $tempErr = Join-Path ([System.IO.Path]::GetTempPath()) "predown-$([guid]::NewGuid().ToString('N')).log"
  try {
    $out = az rest --method $Method --url $Url --output json 2>$tempErr
    $code = $LASTEXITCODE
    $errText = (Get-Content -LiteralPath $tempErr -Raw -ErrorAction SilentlyContinue)
  }
  finally {
    Remove-Item -LiteralPath $tempErr -Force -ErrorAction SilentlyContinue
  }
  if ($code -eq 0) {
    return [pscustomobject]@{ StatusCode = 200; Content = ($out | Out-String) }
  }
  $status = 500
  $m = [regex]::Match($errText, '\((?<c>[45]\d\d)\)')
  if (-not $m.Success) { $m = [regex]::Match($errText, '\b(?<c>[45]\d\d)\b') }
  if ($m.Success) { $status = [int]$m.Groups['c'].Value }
  return [pscustomobject]@{ StatusCode = $status; Content = $errText }
}

function Get-CapabilityHostIds {
  param([string]$Path, [string]$Scope)
  $response = Invoke-ArmRest -Method GET -Url "https://management.azure.com${Path}/capabilityHosts?api-version=$apiVersion"
  if ($response.StatusCode -eq 404) {
    Write-Host "[predown] No $Scope scope found (already deleted). Nothing to enumerate."
    return @()
  }
  if ($response.StatusCode -ge 400) {
    $text = $response.Content
    if ($text -match '(?i)ResourceNotFound|NotFound|was not found') {
      Write-Host "[predown] No $Scope scope found (already deleted). Nothing to enumerate."
      return @()
    }
    throw "[predown] Failed to enumerate $Scope capability hosts (HTTP $($response.StatusCode)): $text"
  }
  $parsed = $response.Content | ConvertFrom-Json
  return @($parsed.value | Where-Object { $_ } | ForEach-Object { $_.id })
}

function Remove-CapabilityHosts {
  param([string[]]$Ids, [string]$Scope)
  foreach ($id in $Ids) {
    Write-Host "[predown] Deleting $Scope capability host: $id"
    # `az resource delete` polls the long-running delete to completion, which is required:
    # project-scope hosts must be fully gone before account-scope deletion.
    az resource delete --ids $id --api-version $apiVersion --output none
    if ($LASTEXITCODE -ne 0) {
      throw "[predown] Failed to delete $Scope capability host (az resource delete exit $LASTEXITCODE): $id"
    }
    Write-Host "[predown] Deleted: $id"
  }
}

$capHostIds = @()

# --- Phase 1: PROJECT-scope capability hosts ---------------------------------------------
$projectPath = "$basePath/projects/$projectName"
$projectIds = Get-CapabilityHostIds -Path $projectPath -Scope 'project'
Remove-CapabilityHosts -Ids $projectIds -Scope 'project'
$capHostIds += $projectIds

# --- Phase 2: ACCOUNT-scope capability hosts ---------------------------------------------
$accountIds = Get-CapabilityHostIds -Path $basePath -Scope 'account'
Remove-CapabilityHosts -Ids $accountIds -Scope 'account'
$capHostIds += $accountIds

if ($capHostIds.Count -eq 0) {
  Write-Host '[predown] No capability hosts found. Nothing to delete.'
}

Write-Host '[predown] Capability-host cleanup complete. azd will now tear down remaining resources.'
