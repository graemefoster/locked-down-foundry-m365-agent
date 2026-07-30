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
