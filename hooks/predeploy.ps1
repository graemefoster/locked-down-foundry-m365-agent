<#
  azd predeploy hook: open the SCM (Kudu) sites so azd can zip-deploy the app code
  --------------------------------------------------------------------------------
  Runs on the azd host BEFORE the deploy phase (azd up / azd deploy). The two code-deployed App
  Services keep their SCM sites deny-by-default at rest (and the MCP app is fully private), so this
  hook temporarily opens them (SCM default action -> Allow, i.e. open to all) for the deploy
  window. The postdeploy hook re-locks them. Opening to all (rather than pinning a deployer IP)
  is robust to a rotating corporate egress IP; Kudu still enforces auth and the window is brief.

    * MCP web app  (private): enable public network access, then open its SCM site.
    * YARP web app (public edge): open its SCM site (main site stays Teams-only).

  Not best-effort: if we cannot open the endpoints the deploy would fail anyway, so azure.yaml sets
  continueOnError: false. See hooks/appservice-scm-common.ps1 for the helpers.
#>
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'appservice-scm-common.ps1')

$resourceGroup = Get-RequiredEnv 'AZURE_RESOURCE_GROUP'
$mcpApp        = Get-RequiredEnv 'MCP_WEBAPP_NAME'
$yarpApp       = Get-RequiredEnv 'TEAMS_YARP_WEBAPP_NAME'

Write-Host "[predeploy] Opening SCM sites (open-to-all) for the deploy window (rg '$resourceGroup')."

# MCP is fully private at rest: enable public access first, THEN open its SCM site.
Set-WebAppPublicNetworkAccess -ResourceGroup $resourceGroup -Name $mcpApp -State 'Enabled'
Open-ScmSite -ResourceGroup $resourceGroup -Name $mcpApp

# YARP main site stays public (Teams ingress); only its SCM site is opened.
Open-ScmSite -ResourceGroup $resourceGroup -Name $yarpApp

Write-Host '[predeploy] SCM sites open. azd will now zip-deploy the MCP + YARP app code.'
