<#
  azd predown hook: deregister the GitHub runner + delete Foundry capability hosts
  --------------------------------------------------------------------------------
  Runs BEFORE `azd down` deletes any resources (so the VM, private endpoints and Key Vault all
  still exist), on the azd host (laptop / CI). Two independent, best-effort phases:

  Phase 0 - GitHub runner deregistration (only if a self-hosted runner was installed):
    Deleting the VM would otherwise leave a stale, permanently "offline" runner registered on
    the repo. VMs have no reliable pre-delete trigger, so we do it here. The PAT lives in Key
    Vault behind a private endpoint, so the actual work must run ON the VM (scripts/
    deregister-runner.ps1, shipped via the vm-run-command.ps1 shim) using the VM managed
    identity over the private data plane.

  Phase 1/2 - Foundry capability-host cleanup:
    A Foundry (Cognitive Services) account/project with an Agents capability host cannot be
    deleted cleanly while the capability host still exists - `azd down` will hang or fail on the
    account. We enumerate the capability hosts on the project (and account, to catch any
    auto-created one) and delete each. This is a control-plane (ARM) operation, so - unlike the
    private data-plane Agents API used by predeploy - it does NOT need the in-VNet VM.

  Best-effort by design: if a phase's inputs can't be resolved (or Foundry / the runner were
  never provisioned), it warns and lets azd proceed. Runner deregistration NEVER fails teardown
  (a stale runner is harmless). Capability-host deletion DOES fail the teardown if a delete
  fails (that would block Foundry deletion anyway, so surfacing it early is clearer).

  Required env vars (surfaced by azd from the Bicep outputs; run `azd env refresh` if missing):
      Capability hosts: AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP, AZURE_AI_ACCOUNT_NAME,
                        AZURE_AI_PROJECT_NAME
      Runner (Phase 0): AZURE_RESOURCE_GROUP, SEED_AGENTS_VM_NAME, GITHUB_RUNNER_REPO_URL,
                        KEY_VAULT_NAME, GITHUB_RUNNER_PAT_SECRET_NAME, GITHUB_RUNNER_USER

  Caller RBAC: permission to delete capability hosts
  (Microsoft.CognitiveServices/accounts/.../capabilityHosts/delete), e.g. Cognitive Services
  Contributor, plus - for Phase 0 - permission to invoke VM run-commands (e.g. Virtual Machine
  Contributor).

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
  $vmName        = Get-OptionalEnv 'SEED_AGENTS_VM_NAME'
  $repoUrl       = Get-OptionalEnv 'GITHUB_RUNNER_REPO_URL'
  $keyVaultName  = Get-OptionalEnv 'KEY_VAULT_NAME'
  $patSecretName = Get-OptionalEnv 'GITHUB_RUNNER_PAT_SECRET_NAME'
  $runnerUser    = Get-OptionalEnv 'GITHUB_RUNNER_USER'

  if ([string]::IsNullOrWhiteSpace($repoUrl)) {
    Write-Host '[predown] No GITHUB_RUNNER_REPO_URL set; no self-hosted runner to deregister. Skipping.'
    return
  }
  if ([string]::IsNullOrWhiteSpace($resourceGroup) -or [string]::IsNullOrWhiteSpace($vmName) `
      -or [string]::IsNullOrWhiteSpace($keyVaultName) -or [string]::IsNullOrWhiteSpace($patSecretName)) {
    Write-Warning "[predown] Runner deregistration needs AZURE_RESOURCE_GROUP, SEED_AGENTS_VM_NAME, KEY_VAULT_NAME and GITHUB_RUNNER_PAT_SECRET_NAME (run 'azd env refresh'). Skipping - the runner may linger as offline."
    return
  }

  $deregisterScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/deregister-runner.ps1'
  if (-not (Test-Path $deregisterScript)) {
    Write-Warning "[predown] Deregister script not found at '$deregisterScript'. Skipping runner deregistration."
    return
  }

  # Ships the .ps1 to the LINUX worker VM and runs it under pwsh (only the VM can reach the
  # private Key Vault to read the PAT and mint a GitHub remove-token).
  . (Join-Path $PSScriptRoot 'vm-run-command.ps1')

  Write-Host "[predown] Deregistering the GitHub runner on VM '$vmName'..."
  $result = Invoke-VmPwshScript `
    -ResourceGroup $resourceGroup `
    -VmName $vmName `
    -ScriptPath $deregisterScript `
    -Parameters @{
      RepoUrl       = $repoUrl
      KeyVaultName  = $keyVaultName
      PatSecretName = $patSecretName
      RunnerUser    = ($runnerUser ?? '')
    }

  $message = ($result.Value | ForEach-Object { $_.Message }) -join "`n"
  Write-Host '----- deregister-runner output (from VM) -----'
  Write-Host $message
  Write-Host '----------------------------------------------'
  if ($message -notmatch '\[deregister-runner\] Done\.') {
    Write-Warning '[predown] Runner deregistration did not report completion (see VM output above). The runner may show as offline until GitHub prunes it.'
  }
  else {
    Write-Host '[predown] Runner deregistration complete.'
  }
}

try {
  Remove-GithubRunner
}
catch {
  Write-Warning "[predown] Runner deregistration failed ($($_.Exception.Message)). Continuing with teardown - the runner may show as offline until GitHub prunes it."
}

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
