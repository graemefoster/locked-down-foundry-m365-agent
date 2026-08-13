<#
  Shared helpers for the predeploy / postdeploy hooks that open and re-lock the SCM (Kudu) sites
  of the two code-deployed App Services (the private MCP app + the public YARP Teams edge) so azd
  can zip-deploy them from the host, then close the window again.

  Both web apps declare (in Bicep) a deny-by-default SCM site:
      scmIpSecurityRestrictionsUseMain: false
      scmIpSecurityRestrictionsDefaultAction: 'Deny'
  so at rest NOTHING may reach Kudu over the public path. The MCP app is additionally fully
  private (publicNetworkAccess: 'Disabled') + private-endpointed.

  Open  (predeploy):  MCP -> enable public access; BOTH -> add an SCM Allow rule for the deployer IP.
  Close (postdeploy): BOTH -> remove that SCM rule; MCP -> re-disable public access.

  Env (azd surfaces Bicep outputs as env vars verbatim; AZURE_* are azd built-ins):
      AZURE_RESOURCE_GROUP   - the resource group (Bicep output).
      MCP_WEBAPP_NAME        - the private MCP web app name (Bicep output).
      TEAMS_YARP_WEBAPP_NAME - the public YARP web app name (Bicep output).
      DEPLOYER_PUBLIC_IP     - optional; the deployer's IP/CIDR (recorded by the preprovision hook).
#>

# The single SCM allow rule the hooks add/remove. Deterministic name so open is idempotent and
# close can delete by name.
$script:ScmDeployRuleName = 'azd-scm-deploy'

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

# Resolve the deployer's public IP as a CIDR the App Service access-restriction API accepts.
# Prefer the value the preprovision hook already recorded (DEPLOYER_PUBLIC_IP); otherwise auto-
# detect via api.ipify.org. A bare IPv4/IPv6 is normalised to /32 (or /128).
function Get-DeployerIpCidr {
  $ip = Get-OptionalEnv 'DEPLOYER_PUBLIC_IP'
  if ([string]::IsNullOrWhiteSpace($ip)) {
    try {
      $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 5).ToString().Trim()
    }
    catch {
      throw "Could not determine the deployer's public IP (DEPLOYER_PUBLIC_IP not set and api.ipify.org unreachable). Set it with 'azd env set DEPLOYER_PUBLIC_IP <ip/cidr>' and retry."
    }
  }
  if ($ip -match '/') { return $ip }
  if ($ip -match ':') { return "$ip/128" }
  return "$ip/32"
}

# Toggle a web app's site-level publicNetworkAccess ('Enabled' / 'Disabled') via a merge update.
function Set-WebAppPublicNetworkAccess {
  param(
    [string]$ResourceGroup,
    [string]$Name,
    [ValidateSet('Enabled', 'Disabled')] [string]$State
  )
  $id = az webapp show -g $ResourceGroup -n $Name --query id -o tsv
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($id)) {
    throw "Failed to resolve web app '$Name' in resource group '$ResourceGroup'."
  }
  az resource update --ids $id --set properties.publicNetworkAccess=$State --output none
  if ($LASTEXITCODE -ne 0) { throw "Failed to set publicNetworkAccess=$State on '$Name'." }
  Write-Host "[$Name] publicNetworkAccess = $State"
}

# Add the temporary deployer-IP Allow rule to the SCM site. Idempotent: an existing rule of the
# same name is removed first so re-runs don't error on a duplicate.
function Open-ScmForDeployer {
  param(
    [string]$ResourceGroup,
    [string]$Name,
    [string]$IpCidr
  )
  az webapp config access-restriction remove -g $ResourceGroup -n $Name `
    --rule-name $script:ScmDeployRuleName --scm-site true --output none 2>$null

  az webapp config access-restriction add -g $ResourceGroup -n $Name `
    --rule-name $script:ScmDeployRuleName --action Allow --priority 100 `
    --ip-address $IpCidr --scm-site true --output none
  if ($LASTEXITCODE -ne 0) { throw "Failed to add the SCM deploy allow-rule to '$Name'." }
  Write-Host "[$Name] SCM site opened for $IpCidr (rule '$($script:ScmDeployRuleName)')."

  # App Service access-restriction changes are NOT immediate - they take ~30-90s to reach the Kudu
  # worker. If azd POSTs the zip before the new Allow rule is live, Kudu answers 403 Ip Forbidden
  # and the deploy fails. Poll the SCM site (from the SAME host/egress azd will deploy from) until
  # it stops returning 403, so we only hand off once the rule is genuinely in effect.
  Wait-ScmDeployerAllowed -Name $Name
}

# Poll the SCM (Kudu) site until the deployer-IP Allow rule is actually in effect. A 403 means the
# rule has not propagated yet; ANY other status (401 auth-challenge, 200, etc.) means the IP is now
# allowed. Runs on the azd host, so its egress matches the one azd's zipdeploy will use.
function Wait-ScmDeployerAllowed {
  param(
    [string]$Name,
    [int]$TimeoutSeconds = 150
  )
  $uri      = "https://$Name.scm.azurewebsites.net/"
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  Write-Host "[$Name] Waiting for the SCM allow rule to take effect ($uri)..."
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
      Write-Host "[$Name] SCM reachable (HTTP $code) - allow rule is live."
      return
    }
    Start-Sleep -Seconds 5
  }
  Write-Host "[$Name] WARNING: SCM still returned 403 after ${TimeoutSeconds}s. The zip-deploy may fail; if so, just re-run 'azd deploy' (the rule is already in place, only propagation was slow)."
}

# Remove the temporary deployer-IP Allow rule, re-locking the SCM site (deny-by-default). Missing
# rule is not an error (already closed).
function Close-ScmForDeployer {
  param(
    [string]$ResourceGroup,
    [string]$Name
  )
  az webapp config access-restriction remove -g $ResourceGroup -n $Name `
    --rule-name $script:ScmDeployRuleName --scm-site true --output none 2>$null
  Write-Host "[$Name] SCM deploy allow-rule removed (SCM re-locked to deny-by-default)."
}
