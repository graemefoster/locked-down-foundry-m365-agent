<#
  azd predown hook: deregister the GitHub runner + delete Foundry capability hosts
  --------------------------------------------------------------------------------
  Runs BEFORE `azd down` deletes any resources (so the VM, private endpoints and Key Vault all
  still exist), on the azd host (laptop / CI). Two independent, best-effort phases:

  Phase 0 - GitHub runner deregistration (only if a self-hosted runner was installed):
    Deleting the VM would otherwise leave a stale, permanently "offline" runner registered on
    the repo. VMs have no reliable pre-delete trigger, so we do it here, HOST-SIDE, with the
    GitHub CLI (`gh`) using the caller's own credentials - no PAT, no Key Vault, no VM round-
    trip. The runner name is deterministic ('<vmName>-vnet', since the bootstrap names it
    '<hostname>-vnet' and the VM's computerName IS the VM name), so we just delete it by name.

  Phase 1/2 - Foundry capability-host cleanup:
    A Foundry (Cognitive Services) account/project with an Agents capability host cannot be
    deleted cleanly while the capability host still exists - `azd down` will hang or fail on the
    account. We enumerate the capability hosts on the project (and account, to catch any
    auto-created one) and delete each. This is a control-plane (ARM) operation, so - unlike the
    runner deregistration in Phase 0 - it does NOT need the in-VNet VM.

  Best-effort by design: if a phase's inputs can't be resolved (or Foundry / the runner were
  never provisioned), it warns and lets azd proceed. Runner deregistration NEVER fails teardown
  (a stale runner is harmless). Capability-host deletion DOES fail the teardown if a delete
  fails (that would block Foundry deletion anyway, so surfacing it early is clearer).

  Required env vars (surfaced by azd from the Bicep outputs; run `azd env refresh` if missing):
      Capability hosts: AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP, AZURE_AI_ACCOUNT_NAME,
                        AZURE_AI_PROJECT_NAME
      Runner (Phase 0): GITHUB_RUNNER_REPO_URL, GITHUB_ACTIONS_RUNNER_VM_NAME (plus the GitHub
                        CLI `gh` on the host, authenticated with admin on the repo)

  Caller RBAC: permission to delete capability hosts
  (Microsoft.CognitiveServices/accounts/.../capabilityHosts/delete), e.g. Cognitive Services
  Contributor. Phase 0 needs no Azure RBAC - just a `gh` login with admin on the repo.

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

# --- Phase 0: deregister the self-hosted GitHub runner (best-effort) ----------------------
# Runs first, and independently of Foundry state, so a stale runner is always cleaned up even
# when Foundry was never provisioned (the Foundry gates below can exit early). Never fails the
# teardown: a lingering offline runner is harmless and GitHub prunes it eventually.
function Remove-GithubRunner {
  $repoUrl = Get-OptionalEnv 'GITHUB_RUNNER_REPO_URL'
  $vmName  = Get-OptionalEnv 'GITHUB_ACTIONS_RUNNER_VM_NAME'

  if ([string]::IsNullOrWhiteSpace($repoUrl)) {
    Write-Host '[predown] No GITHUB_RUNNER_REPO_URL set; no self-hosted runner to deregister. Skipping.'
    return
  }
  if ([string]::IsNullOrWhiteSpace($vmName)) {
    Write-Warning "[predown] GITHUB_ACTIONS_RUNNER_VM_NAME not set (run 'azd env refresh'); cannot derive the runner name. Skipping - the runner may linger as offline."
    return
  }

  # The bootstrap registers the runner as '<hostname>-vnet', and the VM's computerName IS the
  # VM name (infra/stages/40-runner/resources/vm-linux.bicep), so the runner name is fully
  # deterministic from host-side outputs - no need to look anything up on the VM.
  $runnerName = "$vmName-vnet"
  $repoPath   = ($repoUrl -replace '^https?://[^/]+/', '') -replace '/+$', ''

  # gh runs on the HOST with the caller's own credentials, so this needs no PAT, no Key Vault
  # and no VM round-trip - and it still works when the VM's egress is locked down or the VM is
  # already unhealthy. (This repo already assumes `gh` on the host - see hooks/postprovision.ps1.)
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Warning "[predown] GitHub CLI ('gh') not found; cannot deregister runner '$runnerName'. Remove it manually from the repo's Actions settings. Skipping."
    return
  }

  Write-Host "[predown] Deregistering GitHub runner '$runnerName' from '$repoPath' (host-side via gh)..."
  $jq = '.runners[] | select(.name == "' + $runnerName + '") | .id'
  $runnerIds = gh api "repos/$repoPath/actions/runners" --paginate --jq $jq 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "[predown] Could not list runners for '$repoPath' (is gh authenticated with admin on the repo?). Skipping - the runner may linger as offline."
    return
  }
  $ids = @($runnerIds -split '\s+' | Where-Object { $_ })
  if ($ids.Count -eq 0) {
    Write-Host "[predown] No runner named '$runnerName' registered on '$repoPath'. Nothing to deregister."
    return
  }
  # Delete every id that matched the name (guards against accidental duplicates).
  foreach ($id in $ids) {
    gh api -X DELETE "repos/$repoPath/actions/runners/$id" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-Host "[predown] Removed runner '$runnerName' (id=$id)."
    }
    else {
      Write-Warning "[predown] Failed to delete runner id=$id (is gh authenticated with admin on the repo?). It may linger as offline."
    }
  }
}

try {
  Remove-GithubRunner
}
catch {
  Write-Warning "[predown] Runner deregistration failed ($($_.Exception.Message)). Continuing with teardown - the runner may show as offline until GitHub prunes it."
}

# =========================================================================================
# Phases 1/2 setup: resolve the subscription + validate the Foundry inputs before touching
# any capability host. Everything below is control-plane ARM (no VM); each gate is a
# best-effort exit that lets azd proceed when there is nothing (or not enough info) to clean.
# =========================================================================================

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
    # Treat any "not found" flavour as already-gone (idempotent no-op), regardless of the
    # HTTP status. The parent account/project or its workspace may have been deleted out from
    # under us (e.g. a prior partial teardown), which the data plane surfaces as HTTP 500
    # "Workspace not found" rather than a clean 404 — that must not fail 'azd down'.
    if ($text -match '(?i)ResourceNotFound|NotFound|was not found|Workspace not found|does not exist') {
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
    az resource delete --ids $id --api-version $apiVersion
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
