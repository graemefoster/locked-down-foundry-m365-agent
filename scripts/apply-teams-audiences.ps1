param(
  [Parameter(Mandatory = $true)] [string]$FoundryProjectEndpoint,
  [Parameter(Mandatory = $true)] [string]$ResourceGroup,
  [Parameter(Mandatory = $true)] [string]$ApimName,
  [Parameter(Mandatory = $true)] [string]$FoundryAccountName,
  [Parameter(Mandatory = $true)] [string]$FoundryApiPath,
  [Parameter(Mandatory = $false)] [string]$ApiVersion = '2025-11-15-preview'
)

$ErrorActionPreference = 'Stop'

$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')
$projectName = ($FoundryApiPath.Trim('/') -split '/')[-1]
if ([string]::IsNullOrWhiteSpace($projectName)) {
  throw "Could not derive the project name from '$FoundryApiPath'."
}

$teamsAgents = @(
  Get-ChildItem -Path agents -Directory |
    Sort-Object Name |
    Where-Object {
      $networkPath = Join-Path $_.FullName 'network.json'
      if (-not (Test-Path -LiteralPath $networkPath)) {
        return $false
      }
      $network = Get-Content -LiteralPath $networkPath -Raw | ConvertFrom-Json
      return $network.exposeToM365 -eq $true
    } |
    ForEach-Object { $_.Name }
)

$token = az account get-access-token `
  --resource https://ai.azure.com `
  --query accessToken `
  --output tsv

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
  throw "Could not acquire a Foundry token."
}

$tenantId = az account show --query tenantId --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tenantId)) {
  throw "Could not resolve the tenant ID."
}

$headers = @{ Authorization = "Bearer $token" }
$botAppIds = @()

foreach ($agentName in $teamsAgents) {
  $agent = Invoke-RestMethod `
    -Method Get `
    -Uri "$FoundryProjectEndpoint/agents/$agentName`?api-version=$ApiVersion" `
    -Headers $headers

  if ($agent.instance_identity.principal_id) {
    $botAppIds += $agent.instance_identity.principal_id
  }
  else {
    Write-Host "Agent '$agentName' has no principal_id and is excluded from the Teams audience."
  }
}

if ($teamsAgents.Count -gt 0 -and $botAppIds.Count -eq 0) {
  throw "Teams exposure is enabled, but no live bot App IDs were resolved."
}

$audiencePath = Join-Path ([System.IO.Path]::GetTempPath()) "teams-audiences-$([guid]::NewGuid().ToString('N')).json"

try {
  @($botAppIds) | ConvertTo-Json -AsArray | Set-Content -LiteralPath $audiencePath -Encoding utf8

  Write-Host "Applying $($botAppIds.Count) Teams bot audience(s)."

  az deployment group create `
    --resource-group $ResourceGroup `
    --name "teams-audience-$(Get-Date -Format 'yyyyMMddHHmmss')" `
    --template-file infra/stages/30-governance/model-gateway/apim-teams-api.bicep `
    --parameters `
      apimName=$ApimName `
      foundryAccountName=$FoundryAccountName `
      projectName=$projectName `
      expectedTenantId=$tenantId `
      "botAppIds=@$audiencePath" `
    --output none

  if ($LASTEXITCODE -ne 0) {
    throw "Teams audience deployment failed."
  }
}
finally {
  Remove-Item -LiteralPath $audiencePath -Force -ErrorAction SilentlyContinue
}

Write-Host "Teams bot audiences applied."
