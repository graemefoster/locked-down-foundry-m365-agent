<#
  azd postdeploy hook: re-lock the SCM (Kudu) sites after the app code is deployed
  -------------------------------------------------------------------------------
  Runs on the azd host AFTER the deploy phase. Reverses hooks/predeploy.ps1: flips each SCM site's
  default action back to Deny and re-disables public access on the private MCP app, returning both
  web apps to their locked-down posture.

    * YARP web app: re-lock the SCM site (SCM back to deny-by-default; main site unchanged).
    * MCP web app: re-lock the SCM site, then re-disable public network access (private again).

  Best-effort (azure.yaml continueOnError: true): a failed close must not fail an otherwise-good
  deploy, but it leaves the SCM window open — re-run with `azd hooks run postdeploy` to close it.
  See hooks/appservice-scm-common.ps1 for the helpers.
#>
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'appservice-scm-common.ps1')

$resourceGroup = Get-RequiredEnv 'AZURE_RESOURCE_GROUP'
$mcpApp        = Get-RequiredEnv 'MCP_WEBAPP_NAME'
$yarpApp       = Get-RequiredEnv 'TEAMS_YARP_WEBAPP_NAME'

Write-Host "[postdeploy] Re-locking SCM sites (rg '$resourceGroup')."

# YARP: just re-lock the SCM site (main site stays the public Teams ingress).
Close-ScmSite -ResourceGroup $resourceGroup -Name $yarpApp

# MCP: re-lock the SCM site, then take the whole app private again.
Close-ScmSite -ResourceGroup $resourceGroup -Name $mcpApp
Set-WebAppPublicNetworkAccess -ResourceGroup $resourceGroup -Name $mcpApp -State 'Disabled'

Write-Host '[postdeploy] SCM sites re-locked; the MCP app is private again.'
