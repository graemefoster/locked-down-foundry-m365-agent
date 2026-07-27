<#
  Deregister the self-hosted GitHub Actions runner (runs ON the private VM)
  ------------------------------------------------------------------------
  The teardown counterpart of infra/modules/resources/bootstrap-github-runner.sh.
  Executed on the locked-down Linux worker VM by the azd `predown` hook
  (hooks/predown.ps1), which ships this file over `RunShellScript` and runs it under pwsh
  via the hooks/vm-run-command.ps1 shim — BEFORE `azd down` deletes the VM.

  Why on the VM: the fine-grained PAT lives in Key Vault behind a private endpoint, so only
  the VM (via its managed identity, over the private data plane) can read it and mint the
  short-lived runner REMOVE token. Without this, deleting the VM leaves a stale, permanently
  "offline" runner registered on the repo.

  Flow (mirror of the bootstrap):
    1. Acquire a managed-identity token for Key Vault via IMDS (169.254.169.254).
    2. Read the fine-grained PAT from Key Vault over the private data plane.
    3. Mint a short-lived GitHub Actions REMOVE token with that PAT.
    4. Stop + uninstall the systemd service and run `config.sh remove` to deregister.

  Idempotent + best-effort: if no runner is installed it prints the completion marker and
  exits 0, so re-runs (or teardown of an env that never had a runner) are safe. Any step's
  failure is logged but does not abort teardown — the runner will simply show offline until
  GitHub prunes it or you remove it in the repo settings.
#>
param(
  [Parameter(Mandatory = $true)]  [string]$RepoUrl,
  [Parameter(Mandatory = $true)]  [string]$KeyVaultName,
  [Parameter(Mandatory = $true)]  [string]$PatSecretName,
  [Parameter(Mandatory = $false)] [string]$RunnerUser = '',
  [Parameter(Mandatory = $false)] [string]$InstallDir = '/opt/actions-runner'
)
# Best-effort: never let a cleanup hiccup block teardown.
$ErrorActionPreference = 'Continue'

function Write-Log { param([string]$Message) Write-Host "[deregister-runner] $Message" }

# --- 1. Idempotency: nothing to do if the runner was never installed ----------
$svcInstalled = $false
try {
  $units = & systemctl list-units --type=service --all --no-legend 'actions.runner.*' 2>$null
  if ($units -match 'actions\.runner\.') { $svcInstalled = $true }
}
catch {}

$configPresent = Test-Path -LiteralPath (Join-Path $InstallDir '.runner')
if (-not $svcInstalled -and -not $configPresent) {
  Write-Log "No runner service or configuration found at '$InstallDir'. Nothing to deregister."
  Write-Log 'Done.'
  return
}

# --- 2. Managed-identity token for Key Vault (IMDS) ---------------------------
Write-Log 'Acquiring managed-identity token for Key Vault...'
$pat = $null
try {
  $kvTokenResp = Invoke-RestMethod `
    -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' `
    -Headers @{ Metadata = 'true' } -Method Get
  $kvToken = $kvTokenResp.access_token

  # --- 3. Read the PAT from Key Vault (private data plane) --------------------
  Write-Log "Reading PAT secret '$PatSecretName' from Key Vault '$KeyVaultName'..."
  $secretResp = Invoke-RestMethod `
    -Uri "https://$KeyVaultName.vault.azure.net/secrets/$PatSecretName`?api-version=7.4" `
    -Headers @{ Authorization = "Bearer $kvToken" } -Method Get
  $pat = $secretResp.value
}
catch {
  Write-Log "WARNING: could not read the PAT from Key Vault ($($_.Exception.Message))."
}

# --- 4. Mint a REMOVE token and deregister ------------------------------------
$removeToken = $null
if (-not [string]::IsNullOrWhiteSpace($pat)) {
  $repoPath = ($RepoUrl -replace '^https?://[^/]+/', '') -replace '/+$', ''
  Write-Log "Requesting runner remove-token for '$repoPath'..."
  try {
    $tokenResp = Invoke-RestMethod -Method Post `
      -Uri "https://api.github.com/repos/$repoPath/actions/runners/remove-token" `
      -Headers @{
        Authorization          = "Bearer $pat"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'locked-down-foundry-runner-deregister'
      }
    $removeToken = $tokenResp.token
  }
  catch {
    Write-Log "WARNING: could not mint a remove-token ($($_.Exception.Message)). The runner may linger as offline."
  }
}

# Stop + uninstall the systemd service first so the runner is not running during removal.
$svcScript = Join-Path $InstallDir 'svc.sh'
if (Test-Path -LiteralPath $svcScript) {
  Write-Log 'Stopping + uninstalling the runner systemd service...'
  & $svcScript stop 2>$null | Out-Null
  & $svcScript uninstall 2>$null | Out-Null
}

# `config.sh remove` deregisters from GitHub. It refuses to run as root, so run it as the
# runner's owning account (fall back to the .runner directory owner when not supplied).
$configScript = Join-Path $InstallDir 'config.sh'
if ($removeToken -and (Test-Path -LiteralPath $configScript)) {
  if ([string]::IsNullOrWhiteSpace($RunnerUser)) {
    try { $RunnerUser = (& stat -c '%U' $InstallDir 2>$null).Trim() } catch {}
  }
  Write-Log "Deregistering the runner from GitHub (as '$RunnerUser')..."
  & sudo -u $RunnerUser env RUNNER_ALLOW_RUNASROOT=0 $configScript remove --token $removeToken 2>&1 | ForEach-Object { Write-Log $_ }
  if ($LASTEXITCODE -ne 0) {
    Write-Log "WARNING: 'config.sh remove' exited $LASTEXITCODE. The runner may still show as offline in the repo."
  }
  else {
    Write-Log 'Runner deregistered from GitHub.'
  }
}
elseif (-not $removeToken) {
  Write-Log 'No remove-token available; skipped GitHub deregistration (service was still uninstalled locally).'
}

Write-Log 'Done.'
