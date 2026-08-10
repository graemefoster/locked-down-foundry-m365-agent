<#
  create-agent.ps1  (runs ON the private VNet self-hosted runner)
  ---------------------------------------------------------------
  Create-or-update a Foundry agent from a normalized agent JSON file (produced from agent.yaml
  by the `yq` step in the deploy job). If the agent does not exist it is created (POST /agents);
  otherwise a new version is added (POST /agents/{name}/versions). The Foundry API de-duplicates
  identical definitions, so an unchanged definition simply returns the current latest version.

  This step does NOT change which version serves traffic — that is publish-agent.ps1's job.

  The resolved agent name and version are written to $GITHUB_OUTPUT (agent-name, agent-version)
  so the composite action can surface them to the publish step.

  PowerShell 7 (pwsh), cross-platform. Uses the VM managed identity via IMDS (no az login).
#>
param(
  [Parameter(Mandatory = $true)] [string]$AgentJsonPath,
  [Parameter(Mandatory = $true)] [string]$FoundryProjectEndpoint,
  [Parameter(Mandatory = $false)][string]$ApiVersion = '2025-11-15-preview'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'foundry-agent-common.ps1')

$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')

if (-not (Test-Path -LiteralPath $AgentJsonPath)) {
  throw "[create-agent] Agent JSON not found: $AgentJsonPath"
}

Write-Host "[create-agent] Endpoint: $FoundryProjectEndpoint (api-version $ApiVersion)"
Write-Host "[create-agent] Manifest: $AgentJsonPath"

$agent = Get-Content -LiteralPath $AgentJsonPath -Raw | ConvertFrom-Json
$name = $agent.name
if ([string]::IsNullOrWhiteSpace($name)) { throw "[create-agent] Manifest has no 'name'." }
if ($null -eq $agent.definition)          { throw "[create-agent] Manifest has no 'definition'." }

$description = if ($null -ne $agent.description) { [string]$agent.description } else { $null }
$definition  = $agent.definition
$metadata    = $agent.metadata

$token = Get-FoundryToken
Write-Host '[create-agent] Token acquired.'

$existingAgent = Get-AgentByName -Token $token -Endpoint $FoundryProjectEndpoint -ApiVersion $ApiVersion -Name $name

if ($null -ne $existingAgent) {
  Write-Host "[create-agent] Agent '$name' exists - adding a version if the definition changed."
  $before  = Get-LatestAgentVersion -Token $token -Endpoint $FoundryProjectEndpoint -ApiVersion $ApiVersion -Name $name
  $version = New-AgentVersion -Token $token -Endpoint $FoundryProjectEndpoint -ApiVersion $ApiVersion `
    -Name $name -Description $description -Definition $definition -Metadata $metadata
  if ($null -ne $before -and [int]$version -eq [int]$before) {
    Write-Host "[create-agent] Agent '$name' unchanged - still version $version (no new version created)."
  } else {
    Write-Host "[create-agent] Agent '$name' updated -> new version $version."
  }
}
else {
  Write-Host "[create-agent] Agent '$name' does not exist - creating."
  $version = New-Agent -Token $token -Endpoint $FoundryProjectEndpoint -ApiVersion $ApiVersion `
    -Name $name -Description $description -Definition $definition -Metadata $metadata
  if ([string]::IsNullOrWhiteSpace($version)) {
    $version = [string](Get-LatestAgentVersion -Token $token -Endpoint $FoundryProjectEndpoint -ApiVersion $ApiVersion -Name $name)
  }
  Write-Host "[create-agent] Created '$name' at version $version."
}

if ([string]::IsNullOrWhiteSpace($version)) { throw "[create-agent] Could not resolve the agent version." }

if ($env:GITHUB_OUTPUT) {
  "agent-name=$name"       | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
  "agent-version=$version" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}
Write-Host "[create-agent] Done. agent-name=$name agent-version=$version"
