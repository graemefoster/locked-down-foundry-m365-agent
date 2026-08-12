<#
  Shared helpers for the predeploy / postdeploy hooks that open and re-lock the SCM (Kudu) sites
  of the two code-deployed App Services (the private MCP app + the public YARP Teams edge) so azd
  can zip-deploy them from the host, then close the window again.

  Both web apps declare (in Bicep) a deny-by-default SCM site:
      scmIpSecurityRestrictionsUseMain: false
      scmIpSecurityRestrictionsDefaultAction: 'Deny'
  so at rest NOTHING may reach Kudu over the public path. The MCP app is additionally fully
  private (publicNetworkAccess: 'Disabled') + private-endpointed.

  Open  (predeploy):  MCP -> enable public access; BOTH -> flip the SCM default action to Allow
                      (open to all) for the deploy window.
  Close (postdeploy): BOTH -> flip the SCM default action back to Deny; MCP -> re-disable public
                      access.

  Why open-to-all rather than an IP allow-rule? Deployers frequently sit behind a rotating
  corporate NAT (their egress IP changes mid-session), so pinning a single deployer IP is
  brittle. Opening the SCM site for the (short) deploy window and re-locking immediately
  afterwards is robust to a changing egress IP. Kudu still enforces authentication, and the
  window is only open while azd is actively zip-deploying.

  Env (azd surfaces Bicep outputs as env vars verbatim; AZURE_* are azd built-ins):
      AZURE_RESOURCE_GROUP   - the resource group (Bicep output).
      MCP_WEBAPP_NAME        - the private MCP web app name (Bicep output).
      TEAMS_YARP_WEBAPP_NAME - the public YARP web app name (Bicep output).
#>

function Get-RequiredEnv {
  param([string]$Name)
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Required environment variable '$Name' is not set (it is a Bicep output azd surfaces as an env var; run 'azd env refresh' if it is missing)."
  }
  return $value.Trim().Trim('"')
}

function Get-OptionalEnv {
  param([string]$Name)
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) { return $null }
  return $value.Trim().Trim('"')
}

# Run an `az` command with retries. The Azure CLI occasionally dies on a transient network blip
# (e.g. 'Connection aborted / ConnectionResetError(54)') that a simple retry clears. Retries on a
# non-zero exit code up to $MaxAttempts with a short backoff; throws only if every attempt fails.
#   -ReturnOutput : capture and return the command's stdout (for `... --query ... -o tsv` reads).
function Invoke-AzWithRetry {
  param(
    [Parameter(Mandatory)] [scriptblock]$Script,
    [string]$Description = 'az command',
    [switch]$ReturnOutput,
    [int]$MaxAttempts = 4,
    [int]$DelaySeconds = 5
  )
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $global:LASTEXITCODE = 0
    $output = $null
    try {
      if ($ReturnOutput) { $output = & $Script 2>$null } else { & $Script }
    }
    catch {
      # A thrown terminating error (rare for az) is treated like a failed attempt.
      $global:LASTEXITCODE = 1
    }
    if ($LASTEXITCODE -eq 0) { return $output }

    if ($attempt -lt $MaxAttempts) {
      Write-Host "[retry] $Description failed (attempt $attempt/$MaxAttempts, exit $LASTEXITCODE); retrying in ${DelaySeconds}s..."
      Start-Sleep -Seconds $DelaySeconds
    }
  }
  throw "Failed to $Description after $MaxAttempts attempts."
}

# Toggle a web app's site-level publicNetworkAccess ('Enabled' / 'Disabled') via a merge update.
function Set-WebAppPublicNetworkAccess {
  param(
    [string]$ResourceGroup,
    [string]$Name,
    [ValidateSet('Enabled', 'Disabled')] [string]$State
  )
  $id = Invoke-AzWithRetry -Description "resolve web app '$Name'" -ReturnOutput -Script {
    az webapp show -g $ResourceGroup -n $Name --query id -o tsv
  }
  if ([string]::IsNullOrWhiteSpace($id)) {
    throw "Failed to resolve web app '$Name' in resource group '$ResourceGroup'."
  }
  Invoke-AzWithRetry -Description "set publicNetworkAccess=$State on '$Name'" -Script {
    az resource update --ids $id --set properties.publicNetworkAccess=$State --output none
  }
  Write-Host "[$Name] publicNetworkAccess = $State"
}

# Set a web app's SCM (Kudu) IP-restriction default action ('Allow' opens it to everyone; 'Deny'
# re-locks it to deny-by-default). Applied to the site's web config.
function Set-ScmDefaultAction {
  param(
    [string]$ResourceGroup,
    [string]$Name,
    [ValidateSet('Allow', 'Deny')] [string]$Action
  )
  $id = Invoke-AzWithRetry -Description "resolve web app '$Name'" -ReturnOutput -Script {
    az webapp show -g $ResourceGroup -n $Name --query id -o tsv
  }
  if ([string]::IsNullOrWhiteSpace($id)) {
    throw "Failed to resolve web app '$Name' in resource group '$ResourceGroup'."
  }
  Invoke-AzWithRetry -Description "set SCM default action=$Action on '$Name'" -Script {
    az resource update --ids "$id/config/web" `
      --set properties.scmIpSecurityRestrictionsDefaultAction=$Action --output none
  }
  Write-Host "[$Name] SCM default action = $Action"
}

# Open the SCM site to all (default action Allow) for the deploy window, then wait until Kudu is
# actually reachable so azd doesn't zip-deploy into a not-yet-propagated 403.
function Open-ScmSite {
  param(
    [string]$ResourceGroup,
    [string]$Name
  )
  Set-ScmDefaultAction -ResourceGroup $ResourceGroup -Name $Name -Action 'Allow'
  Write-Host "[$Name] SCM site opened (default action Allow — open to all for the deploy window)."
  Wait-ScmReachable -Name $Name
}

# Poll the SCM (Kudu) site until the open is actually in effect. A 403 means the default-action
# change has not propagated yet; ANY other status (401 auth-challenge, 200, etc.) means Kudu is now
# reachable. Runs on the azd host, so its egress matches the one azd's zipdeploy will use.
function Wait-ScmReachable {
  param(
    [string]$Name,
    [int]$TimeoutSeconds = 150
  )
  $uri      = "https://$Name.scm.azurewebsites.net/"
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  Write-Host "[$Name] Waiting for the SCM open to take effect ($uri)..."
  while ((Get-Date) -lt $deadline) {
    $code = 0
    try {
      $resp = Invoke-WebRequest -Uri $uri -Method Get -TimeoutSec 10 -SkipHttpErrorCheck
      $code = [int]$resp.StatusCode
    }
    catch {
      # Network-level failure (DNS/TLS/timeout): treat as not-yet-ready and keep polling. If the
      # server responded (rare, e.g. an unfollowed redirect), pull the status out of the exception.
      if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
    }
    if ($code -ne 0 -and $code -ne 403) {
      Write-Host "[$Name] SCM reachable (HTTP $code) - open is live."
      return
    }
    Start-Sleep -Seconds 5
  }
  Write-Host "[$Name] WARNING: SCM still returned 403 after ${TimeoutSeconds}s. The zip-deploy may fail; if so, just re-run 'azd deploy' (the site is already open, only propagation was slow)."
}

# Re-lock the SCM site (default action Deny). Idempotent — safe to call when already locked. Also
# removes any lingering 'azd-scm-deploy' IP allow-rule left by the older IP-pinned hook, so a
# migration from that approach doesn't leave a stale per-IP hole open.
function Close-ScmSite {
  param(
    [string]$ResourceGroup,
    [string]$Name
  )
  az webapp config access-restriction remove -g $ResourceGroup -n $Name `
    --rule-name 'azd-scm-deploy' --scm-site true --output none 2>$null
  Set-ScmDefaultAction -ResourceGroup $ResourceGroup -Name $Name -Action 'Deny'
  Write-Host "[$Name] SCM re-locked to deny-by-default."
}
