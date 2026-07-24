<#
  publish-agent.ps1  (runs ON the private VNet self-hosted runner)
  ----------------------------------------------------------------
  Publish an agent version: route 100% of the agent endpoint's traffic to the given version.
  This is the "Publish Updates" action in the new agent endpoint model - the stable endpoint
  URL is unchanged; only the served version selector is updated (merge-patch, so any existing
  protocol_configuration / authorization_schemes are preserved).

  Windows PowerShell 5.1 compatible. Uses the VM managed identity via IMDS (no az login).
#>
param(
  [Parameter(Mandatory = $true)] [string]$AgentName,
  [Parameter(Mandatory = $true)] [string]$AgentVersion,
  [Parameter(Mandatory = $true)] [string]$FoundryProjectEndpoint,
  [Parameter(Mandatory = $false)][string]$ApiVersion = '2025-11-15-preview'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'foundry-agent-common.ps1')

$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')

Write-Host "[publish-agent] Endpoint: $FoundryProjectEndpoint (api-version $ApiVersion)"
Write-Host "[publish-agent] Publishing '$AgentName' version $AgentVersion (100% traffic)."

$token = Get-FoundryToken
Write-Host '[publish-agent] Token acquired.'

Set-ServedAgentVersion -Token $token -Endpoint $FoundryProjectEndpoint -ApiVersion $ApiVersion `
  -Name $AgentName -Version $AgentVersion

Write-Host "[publish-agent] Done. '$AgentName' now serving version $AgentVersion."
