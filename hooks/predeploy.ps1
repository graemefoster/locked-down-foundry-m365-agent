<#
  azd predeploy hook: open the SCM (Kudu) sites so azd can zip-deploy the app code
  --------------------------------------------------------------------------------
  Runs on the azd host BEFORE the deploy phase (azd up / azd deploy). The two code-deployed App
  Services keep their SCM sites deny-by-default at rest (and the MCP app is fully private), so this
  hook temporarily opens them for the deployer's public IP. The postdeploy hook re-locks them.

    * MCP web app  (private): enable public network access, then allow the deployer IP on SCM.
    * YARP web app (public edge): allow the deployer IP on SCM (main site stays Teams-only).

  Not best-effort: if we cannot open the endpoints the deploy would fail anyway, so azure.yaml sets
  continueOnError: false. See hooks/appservice-scm-common.ps1 for the helpers.
#>
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'appservice-scm-common.ps1')

$resourceGroup = Get-RequiredEnv 'AZURE_RESOURCE_GROUP'
$mcpApp        = Get-RequiredEnv 'MCP_WEBAPP_NAME'
$yarpApp       = Get-RequiredEnv 'TEAMS_YARP_WEBAPP_NAME'
$ipCidr        = Get-DeployerIpCidr

Write-Host "[predeploy] Opening SCM sites for deployer $ipCidr (rg '$resourceGroup')."

# MCP is fully private at rest: enable public access first, THEN scope SCM to the deployer IP.
Set-WebAppPublicNetworkAccess -ResourceGroup $resourceGroup -Name $mcpApp -State 'Enabled'
Open-ScmForDeployer -ResourceGroup $resourceGroup -Name $mcpApp -IpCidr $ipCidr

# YARP main site stays public (Teams ingress); only its SCM site is opened for the deployer.
Open-ScmForDeployer -ResourceGroup $resourceGroup -Name $yarpApp -IpCidr $ipCidr

Write-Host '[predeploy] SCM sites open. azd will now zip-deploy the MCP + YARP app code.'
