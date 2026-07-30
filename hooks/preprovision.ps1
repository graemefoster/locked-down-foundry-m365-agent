<#
  azd preprovision hook: interactive first-run configuration
  ----------------------------------------------------------
  Runs on the azd host (laptop / CI) before every `azd provision` (including the provision
  phase of `azd up`). Prompts once for the two optional deployment choices that would
  otherwise require a manual `azd env set`:

      * DEPLOY_WINDOWS_VM      — deploy the RDP-in Windows dev VM (+ Azure Bastion)?
      * GITHUB_RUNNER_REPO_URL — install the in-VNet self-hosted GitHub Actions runner?
      * DEPLOYER_PUBLIC_IP     — allow THIS machine's public IP through the YARP edge (opt-in)?

  The answers are persisted to the azd environment (.azure/<env>/.env), which
  infra/main.parameters.json reads via ${VAR=default}. This hook therefore only records the
  user's choice; the Bicep defaults still apply when it is skipped.

  Idempotent + non-interactive safe:
    * A value already present in the azd environment is left untouched, so re-runs and any
      explicit `azd env set` overrides win and the user is never re-nagged.
    * Non-interactive shells (e.g. CI) skip prompting entirely and fall back to the
      parameters.json defaults / any pre-set env values.

  The runner PAT is a secret and is deliberately NOT prompted here — set it with
  `azd env set GITHUB_RUNNER_PAT <fine-grained-PAT>`. See docs/github-runner.md.
#>
$ErrorActionPreference = 'Stop'

# True when the azd environment already holds this key (any value, including empty),
# i.e. the user has answered before or set it explicitly. `azd env get-value` exits
# non-zero only when the key is absent.
function Test-AzdEnvKeySet {
  param([string]$Name)
  $null = azd env get-value $Name 2>$null
  return ($LASTEXITCODE -eq 0)
}

$interactive = [Environment]::UserInteractive -and [string]::IsNullOrEmpty($env:CI)
if (-not $interactive) {
  Write-Host '[preprovision] Non-interactive shell; skipping prompts (using existing env / parameters.json defaults).'
  return
}

Write-Host ''
Write-Host '=== azd first-run configuration (press Enter to accept the default) ==='

# 1) Windows dev VM (+ Bastion). Always resolves to true/false, so it doubles as its own marker.
if (Test-AzdEnvKeySet 'DEPLOY_WINDOWS_VM') {
  Write-Host "[preprovision] DEPLOY_WINDOWS_VM already set ($(azd env get-value DEPLOY_WINDOWS_VM)); leaving as-is."
}
else {
  $answer = Read-Host 'Deploy the Windows dev VM (RDP via Bastion, extra cost)? [y/N]'
  $deployWinVm = if ($answer.Trim() -match '^(y|yes)$') { 'true' } else { 'false' }
  azd env set DEPLOY_WINDOWS_VM $deployWinVm | Out-Null
  Write-Host "[preprovision] DEPLOY_WINDOWS_VM = $deployWinVm"
}

# 2) In-VNet self-hosted GitHub Actions runner (opt-in). Blank = disabled; we still record
#    the (empty) key so the choice is remembered and not re-prompted next run.
if (Test-AzdEnvKeySet 'GITHUB_RUNNER_REPO_URL') {
  $existing = azd env get-value GITHUB_RUNNER_REPO_URL
  $shown = if ([string]::IsNullOrWhiteSpace($existing)) { '(none)' } else { $existing }
  Write-Host "[preprovision] GITHUB_RUNNER_REPO_URL already set ($shown); leaving as-is."
}
else {
  Write-Host 'Optional: install a self-hosted GitHub Actions runner on the in-VNet Linux VM'
  Write-Host '          so deployments run inside the VNet (see docs/github-runner.md).'
  $repoUrl = (Read-Host 'GitHub repo URL for the self-hosted runner (blank = skip)').Trim()
  azd env set GITHUB_RUNNER_REPO_URL $repoUrl | Out-Null
  if ([string]::IsNullOrWhiteSpace($repoUrl)) {
    Write-Host '[preprovision] GITHUB_RUNNER_REPO_URL = (none); self-hosted runner disabled.'
  }
  else {
    Write-Host "[preprovision] GITHUB_RUNNER_REPO_URL = $repoUrl"
    if (-not (Test-AzdEnvKeySet 'GITHUB_RUNNER_PAT')) {
      Write-Host ''
      Write-Host '  IMPORTANT: the runner needs a fine-grained PAT (Administration: read & write).'
      Write-Host '  It is a secret, so it is not prompted here. Set it before provisioning with:'
      Write-Host '      azd env set GITHUB_RUNNER_PAT <fine-grained-PAT>'
    }
  }
}

# 3) Deployer public IP allow (opt-in). The YARP public edge defaults to deny-by-default with
#    only Microsoft Teams' service IP ranges allowed, so a developer testing /agents or /teams
#    from their laptop is blocked at the network layer. Offer to punch THIS machine's current
#    public IP through as an Allow rule. Off by default (blank key recorded so it is remembered):
#    the IP is only a network-layer gate — the caller STILL needs a valid Entra token + an
#    agent-network.json allowlist entry to reach a Foundry agent, so this does not weaken auth.
if (Test-AzdEnvKeySet 'DEPLOYER_PUBLIC_IP') {
  $existing = azd env get-value DEPLOYER_PUBLIC_IP
  $shown = if ([string]::IsNullOrWhiteSpace($existing)) { '(none)' } else { $existing }
  Write-Host "[preprovision] DEPLOYER_PUBLIC_IP already set ($shown); leaving as-is."
}
else {
  $myIp = ''
  try {
    $myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 5).ToString().Trim()
  }
  catch {
    Write-Host '[preprovision] Could not auto-detect your public IP (api.ipify.org unreachable).'
  }
  $prompt = if ([string]::IsNullOrWhiteSpace($myIp)) {
    'Allow your public IP through the YARP edge? Enter an IP/CIDR (blank = skip)'
  }
  else {
    "Allow your public IP ($myIp) through the YARP edge? [y/N, or enter a different IP/CIDR]"
  }
  $answer = (Read-Host $prompt).Trim()
  $deployerIp = if ($answer -match '^(y|yes)$') { $myIp }
                elseif ($answer -match '^(n|no)?$') { '' }
                else { $answer }
  azd env set DEPLOYER_PUBLIC_IP $deployerIp | Out-Null
  if ([string]::IsNullOrWhiteSpace($deployerIp)) {
    Write-Host '[preprovision] DEPLOYER_PUBLIC_IP = (none); only Microsoft Teams ranges reach the edge.'
  }
  else {
    Write-Host "[preprovision] DEPLOYER_PUBLIC_IP = $deployerIp (added as a YARP Allow rule)."
  }
}

Write-Host '======================================================================'
Write-Host ''