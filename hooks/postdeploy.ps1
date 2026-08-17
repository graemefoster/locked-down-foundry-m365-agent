<#
  azd postdeploy hook: re-lock the SCM (Kudu) sites after the app code is deployed
  -------------------------------------------------------------------------------
  Runs on the azd host AFTER the deploy phase. Reverses hooks/predeploy.ps1: removes the temporary
  deployer-IP allow rule from each SCM site and re-disables public access on the private MCP app,
  returning both web apps to their locked-down posture.

    * YARP web app: remove the SCM allow rule (SCM back to deny-by-default; main site unchanged).
    * MCP web app: remove the SCM allow rule, then re-disable public network access (private again).

  Best-effort (azure.yaml continueOnError: true): a failed close must not fail an otherwise-good
  deploy, but it leaves the SCM window open — re-run with `azd hooks run postdeploy` to close it.
  See hooks/appservice-scm-common.ps1 for the helpers.
#>
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'appservice-scm-common.ps1')

$resourceGroup = Get-RequiredEnv 'AZURE_RESOURCE_GROUP'
$mcpAppDev     = Get-RequiredEnv 'MCP_WEBAPP_NAME_DEV'
$mcpAppTest    = Get-RequiredEnv 'MCP_WEBAPP_NAME_TEST'
$yarpApp       = Get-RequiredEnv 'TEAMS_YARP_WEBAPP_NAME'

Write-Host "[postdeploy] Re-locking SCM sites (rg '$resourceGroup')."

# YARP: just remove the temporary SCM allow rule (main site stays the public Teams ingress).
Close-ScmForDeployer -ResourceGroup $resourceGroup -Name $yarpApp

# Both MCP apps (dev + test): remove the SCM allow rule, then take each app private again.
foreach ($mcpApp in @($mcpAppDev, $mcpAppTest)) {
  Close-ScmForDeployer -ResourceGroup $resourceGroup -Name $mcpApp
  Set-WebAppPublicNetworkAccess -ResourceGroup $resourceGroup -Name $mcpApp -State 'Disabled'
}

Write-Host '[postdeploy] SCM sites re-locked; the MCP apps are private again.'
