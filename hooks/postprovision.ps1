<#
  azd postprovision hook: push provisioning outputs to GitHub repo variables
  --------------------------------------------------------------------------
  Runs on the azd host (laptop / CI) AFTER `azd provision` succeeds. Copies the Bicep outputs
  that the in-VNet GitHub Actions workflows consume (as `${{ vars.* }}`) into the repository's
  Actions variables, so the deploy workflows "just work" without anyone hand-copying values out
  of `azd env get-values` into repo Settings.

  This is a lightweight, host-side `gh` call ONLY. It does NOT run any agent deploys, MCP
  compliance or Teams publishing (those remain the sole job of the in-VNet self-hosted runner
  workflows) and it never touches the private VNet - so it does not reintroduce the old
  `az vm run-command` orchestration.

  Variable mapping (repo variable  <-  azd output / env var):
      Same-named Bicep outputs are copied 1:1. The only rename is MCP_SERVER_URL <- MCP_GATEWAY_URL
      (the workflows read `vars.MCP_SERVER_URL`; the Bicep output is named MCP_GATEWAY_URL).
      TEAMS_PUBLISH_SCOPE is a manual choice (no Bicep output) and is left for the operator to set.

  Idempotent: `gh variable set` creates-or-updates, so re-running just refreshes the values.

  Best-effort (continueOnError: true in azure.yaml): if `gh` is missing / not authenticated, or
  an output is absent, it warns and lets azd finish - a failed variable push must never fail an
  otherwise-successful provision. Re-run any time with `azd hooks run postprovision`.

  Requires: the GitHub CLI (`gh`), authenticated (`gh auth login`) with permission to write repo
  Actions variables (repo admin, or a token with the `repo`/`variables` scope). Reads the target
  repo from GITHUB_RUNNER_REPO_URL when set, otherwise falls back to gh's git-remote detection.
#>
$ErrorActionPreference = 'Stop'

function Get-OptionalEnv {
  param([string]$Name)
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) { return $null }
  return $value.Trim().Trim('"')
}

# --- Preconditions: gh present + authenticated (best-effort; warn and skip otherwise) ---------
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Warning '[postprovision] GitHub CLI (gh) not found; skipping repo-variable sync. Install gh and re-run `azd hooks run postprovision`.'
  return
}
gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Warning '[postprovision] gh is not authenticated; skipping repo-variable sync. Run `gh auth login` and re-run `azd hooks run postprovision`.'
  return
}

# --- Resolve the target repo (owner/name) -----------------------------------------------------
# Prefer the explicit runner repo URL (that is where the workflows + runner live); otherwise let
# gh infer it from the current git remote.
$repoArgs = @()
$repoUrl  = Get-OptionalEnv 'GITHUB_RUNNER_REPO_URL'
if ($repoUrl) {
  $slug = ($repoUrl -replace '^https?://github\.com/', '') -replace '\.git$', ''
  $slug = $slug.Trim('/')
  if ($slug) { $repoArgs = @('--repo', $slug) }
}

# --- Variable mapping: repo variable name  ->  source env var (Bicep output) -------------------
# Ordered for readable output. Same name unless noted (MCP_SERVER_URL <- MCP_GATEWAY_URL).
$variableMap = [ordered]@{
  AZURE_RESOURCE_GROUP           = 'AZURE_RESOURCE_GROUP'
  AZURE_AI_PROJECT_ENDPOINT      = 'AZURE_AI_PROJECT_ENDPOINT'
  AZURE_AI_MODEL_DEPLOYMENT_NAME = 'AZURE_AI_MODEL_DEPLOYMENT_NAME'
  MCP_SERVER_URL                 = 'MCP_GATEWAY_URL'
  MCP_COMPLIANCE_APIM_NAME       = 'MCP_COMPLIANCE_APIM_NAME'
  MCP_COMPLIANCE_AUDIENCE        = 'MCP_COMPLIANCE_AUDIENCE'
  TEAMS_BOT_NAME                 = 'TEAMS_BOT_NAME'
  TEAMS_NAME_PREFIX              = 'TEAMS_NAME_PREFIX'
  TEAMS_TENANT_ID                = 'TEAMS_TENANT_ID'
  TEAMS_YARP_FQDN                = 'TEAMS_YARP_FQDN'
  TEAMS_LOG_ANALYTICS_ID         = 'TEAMS_LOG_ANALYTICS_ID'
}

$target = if ($repoArgs.Count) { $repoArgs[1] } else { '(current git remote)' }
Write-Host "[postprovision] Syncing GitHub Actions variables on $target ..."

$set = 0
$skipped = @()
foreach ($repoVar in $variableMap.Keys) {
  $value = Get-OptionalEnv $variableMap[$repoVar]
  if ([string]::IsNullOrWhiteSpace($value)) {
    $skipped += $repoVar
    continue
  }
  gh variable set $repoVar @repoArgs --body $value
  if ($LASTEXITCODE -eq 0) {
    Write-Host "  [+] $repoVar"
    $set++
  } else {
    Write-Warning "  [!] Failed to set $repoVar (gh exit $LASTEXITCODE)."
  }
}

Write-Host "[postprovision] Set $set variable(s)."
if ($skipped.Count) {
  Write-Warning "[postprovision] Skipped (output not present - run 'azd env refresh' if unexpected): $($skipped -join ', ')"
}

# TEAMS_PUBLISH_SCOPE has no Bicep output - it is an operator choice (the Teams admin publish
# scope). Nudge the operator to set it once so the Teams-publish path works.
$teamsScope = Get-OptionalEnv 'TEAMS_PUBLISH_SCOPE'
if ([string]::IsNullOrWhiteSpace($teamsScope)) {
  Write-Host "[postprovision] Note: TEAMS_PUBLISH_SCOPE has no provisioning output. Set it manually if you use Teams publishing:"
  Write-Host "                gh variable set TEAMS_PUBLISH_SCOPE $($repoArgs -join ' ') --body <scope>"
}
