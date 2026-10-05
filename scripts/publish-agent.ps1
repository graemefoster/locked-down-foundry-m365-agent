#!/usr/bin/env pwsh

param(
  [Parameter(Mandatory = $true)] [string]$AgentDirectory,
  [Parameter(Mandatory = $false)] [string]$FoundryProjectEndpoint = $env:AZURE_AI_PROJECT_ENDPOINT,
  [Parameter(Mandatory = $false)] [string]$PublishAccessToken = '',
  [Parameter(Mandatory = $false)] [string]$ResourceGroup = $env:AZURE_RESOURCE_GROUP,
  [Parameter(Mandatory = $false)] [string]$YarpFqdn = $env:TEAMS_YARP_FQDN,
  [Parameter(Mandatory = $false)] [string]$TenantId = $env:TEAMS_TENANT_ID,
  [Parameter(Mandatory = $false)] [string]$BotName = $env:TEAMS_BOT_NAME,
  [Parameter(Mandatory = $false)] [string]$LogAnalyticsWorkspaceId = $env:TEAMS_LOG_ANALYTICS_ID
)

$ErrorActionPreference = 'Stop'

$agentDirectoryPath = (Resolve-Path -LiteralPath $AgentDirectory).Path
$agentPath = Join-Path $agentDirectoryPath 'agent.yaml'
$autopilotPath = Join-Path $agentDirectoryPath 'autopilot.json'
$teamsPath = Join-Path $agentDirectoryPath 'teams.json'

if (-not (Test-Path -LiteralPath $agentPath)) {
  throw "Agent deployment manifest not found: $agentPath"
}
if ([string]::IsNullOrWhiteSpace($FoundryProjectEndpoint)) {
  throw 'FoundryProjectEndpoint is required. Pass it explicitly or set AZURE_AI_PROJECT_ENDPOINT.'
}

$hasAutopilot = Test-Path -LiteralPath $autopilotPath
$hasTeams = Test-Path -LiteralPath $teamsPath
if ($hasAutopilot -and $hasTeams) {
  throw "Agent directory '$agentDirectoryPath' contains both autopilot.json and teams.json."
}
if (-not $hasAutopilot -and -not $hasTeams) {
  throw "Agent directory '$agentDirectoryPath' has no autopilot.json or teams.json publishing metadata."
}

if ([string]::IsNullOrWhiteSpace($PublishAccessToken)) {
  $az = Get-Command az -ErrorAction SilentlyContinue
  if ($null -eq $az) {
    throw "Azure CLI is required. Install 'az', then sign in with a delegated user."
  }

  $signedInUser = az ad signed-in-user show --query userPrincipalName --output tsv
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($signedInUser)) {
    throw 'Microsoft 365 publishing requires a delegated user. Run az login --use-device-code --tenant <tenant-id>.'
  }
  Write-Host "Publishing as delegated user: $signedInUser"

  $PublishAccessToken = az account get-access-token `
    --resource https://ai.azure.com `
    --query accessToken `
    --output tsv
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($PublishAccessToken)) {
    throw 'Could not acquire the delegated Microsoft Foundry token.'
  }
}

if ($hasAutopilot) {
  & "$PSScriptRoot/publish-autopilot.ps1" `
    -AgentDirectory $agentDirectoryPath `
    -FoundryProjectEndpoint $FoundryProjectEndpoint `
    -PublishAccessToken $PublishAccessToken
  return
}

$requiredTeamsValues = [ordered]@{
  ResourceGroup = $ResourceGroup
  YarpFqdn      = $YarpFqdn
  TenantId      = $TenantId
  BotName       = $BotName
}
foreach ($item in $requiredTeamsValues.GetEnumerator()) {
  if ([string]::IsNullOrWhiteSpace([string]$item.Value)) {
    throw "$($item.Key) is required for Teams publishing."
  }
}

& "$PSScriptRoot/publish-teams.ps1" `
  -AgentDirectory $agentDirectoryPath `
  -FoundryProjectEndpoint $FoundryProjectEndpoint `
  -ResourceGroup $ResourceGroup `
  -YarpFqdn $YarpFqdn `
  -TenantId $TenantId `
  -BotName $BotName `
  -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId `
  -PublishAccessToken $PublishAccessToken
