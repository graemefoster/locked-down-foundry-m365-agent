<#
  azd predown hook: delete Foundry capability hosts before teardown
  -----------------------------------------------------------------
  A Foundry (Cognitive Services) account/project with an Agents capability host cannot be
  deleted cleanly while the capability host still exists - `azd down` will hang or fail on the
  account. This hook runs BEFORE azd deletes any resources, enumerates the capability hosts on
  the project (and account, to catch any auto-created one), and deletes each. `az resource
  delete` polls the long-running delete operation to completion, so azd only proceeds once the
  capability hosts are gone.

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

# Subscription can also be discovered from the logged-in az context.
if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
  $subscriptionId = (az account show --query id --output tsv 2>$null)
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
# A half-populated env (one name present, the other missing) is anomalous - fail rather than
# risk leaving the project capability host behind, which would make azd's Foundry delete fail.
if (-not $hasProject) {
  throw "[predown] AZURE_AI_ACCOUNT_NAME is set but AZURE_AI_PROJECT_NAME is missing. Cannot delete the project-scope capability host. Run 'azd env refresh' and retry 'azd down'."
}
if (-not $hasAccount) {
  throw "[predown] AZURE_AI_PROJECT_NAME is set but AZURE_AI_ACCOUNT_NAME is missing. Cannot build the capability-host resource path. Run 'azd env refresh' and retry 'azd down'."
}

$base = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.CognitiveServices/accounts/$accountName"

function Get-CapabilityHostIds {
  param([string]$ListUrl, [string]$Scope)
  # Merge stderr so we can inspect the error text; az writes JSON to stdout on success.
  $raw = az rest --method get --url "$ListUrl" --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    $text = ($raw | Out-String)
    # Parent scope already gone (e.g. re-run after a partial down) - nothing to enumerate.
    if ($text -match '(?i)ResourceNotFound|NotFound|was not found|\b404\b') {
      Write-Host "[predown] No $Scope scope found (already deleted). Nothing to enumerate."
      return @()
    }
    # A real failure (RBAC denial, transient/server error) must NOT be treated as "no hosts",
    # or we could proceed and leave a blocking capability host behind.
    throw "[predown] Failed to enumerate $Scope capability hosts (exit $LASTEXITCODE): $text"
  }
  # On success $raw may be stdout JSON lines possibly mixed with stderr warning records
  # (from 2>&1) - e.g. az CLI upgrade notices, common with -preview API versions. Keep only
  # the string (stdout) lines before parsing, or ConvertFrom-Json would choke on a warning.
  $json = ($raw | Where-Object { $_ -is [string] }) -join "`n"
  if ([string]::IsNullOrWhiteSpace($json)) { return @() }
  $parsed = $json | ConvertFrom-Json
  return @($parsed.value | Where-Object { $_ } | ForEach-Object { $_.id })
}

function Remove-CapabilityHosts {
  param([string[]]$Ids, [string]$Scope)
  foreach ($id in $Ids) {
    Write-Host "[predown] Deleting $Scope capability host: $id"
    az resource delete --ids "$id" --api-version $apiVersion --output none
    if ($LASTEXITCODE -ne 0) {
      throw "[predown] Failed to delete capability host '$id' (exit code $LASTEXITCODE). Resolve this before retrying 'azd down', otherwise Foundry deletion will fail."
    }
    Write-Host "[predown] Deleted: $id"
  }
}

$capHostIds = @()

# --- Phase 1: PROJECT-scope capability hosts ---------------------------------------------
# These are the blocking hosts this template creates. They MUST be deleted first - and
# confirmed gone (az resource delete polls the LRO) - before we touch the account, or the
# account-scope delete / azd's Foundry teardown will fail. Project name is guaranteed present
# by the gate above.
$projectListUrl = "$base/projects/$projectName/capabilityHosts?api-version=$apiVersion"
$projectIds = Get-CapabilityHostIds -ListUrl $projectListUrl -Scope 'project'
Remove-CapabilityHosts -Ids $projectIds -Scope 'project'
$capHostIds += $projectIds

# --- Phase 2: ACCOUNT-scope capability hosts ---------------------------------------------
# Only after every project host is gone. Catches any auto-created account-level host.
$accountListUrl = "$base/capabilityHosts?api-version=$apiVersion"
$accountIds = Get-CapabilityHostIds -ListUrl $accountListUrl -Scope 'account'
Remove-CapabilityHosts -Ids $accountIds -Scope 'account'
$capHostIds += $accountIds

if ($capHostIds.Count -eq 0) {
  Write-Host '[predown] No capability hosts found. Nothing to delete.'
}

Write-Host '[predown] Capability-host cleanup complete. azd will now tear down remaining resources.'
