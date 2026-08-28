param(
  [Parameter(Mandatory = $true)] [string]$AgentDirectory,
  [Parameter(Mandatory = $true)] [string]$FoundryProjectEndpoint,
  [Parameter(Mandatory = $true)] [string]$ResourceGroup,
  [Parameter(Mandatory = $true)] [string]$YarpFqdn,
  [Parameter(Mandatory = $true)] [string]$TenantId,
  [Parameter(Mandatory = $true)] [string]$BotName,
  [Parameter(Mandatory = $true)] [string]$PublishAccessToken,
  [Parameter(Mandatory = $false)] [string]$LogAnalyticsWorkspaceId = ''
)

$ErrorActionPreference = 'Stop'

$agentPath = Join-Path $AgentDirectory 'agent.json'
$networkPath = Join-Path $AgentDirectory 'network.json'
$teamsPath = Join-Path $AgentDirectory 'teams.json'
$botTemplate = Join-Path (Split-Path $PSScriptRoot -Parent) 'hooks/bot-service.bicep'

foreach ($path in @($agentPath, $networkPath, $teamsPath, $botTemplate)) {
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Required file not found: $path"
  }
}

$agent = Get-Content -LiteralPath $agentPath -Raw | ConvertFrom-Json
$network = Get-Content -LiteralPath $networkPath -Raw | ConvertFrom-Json
$teams = Get-Content -LiteralPath $teamsPath -Raw | ConvertFrom-Json
$agentName = $agent.name

if ($network.exposeToM365 -ne $true) {
  Write-Host "Teams publishing is disabled for '$agentName'."
  return
}

$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')
$agentUrl = "$FoundryProjectEndpoint/agents/$agentName`?api-version=v1"

Write-Host "Publishing '$agentName' to Teams / Microsoft 365."

$managedIdentityToken = az account get-access-token `
  --resource https://ai.azure.com `
  --query accessToken `
  --output tsv

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($managedIdentityToken)) {
  throw "Could not acquire the VM managed-identity token."
}
if ([string]::IsNullOrWhiteSpace($PublishAccessToken)) {
  throw "A delegated user token is required for Microsoft 365 publishing."
}

Write-Host "Step 1: reading the agent identity."

$liveAgent = Invoke-RestMethod `
  -Method Get `
  -Uri $agentUrl `
  -Headers @{ Authorization = "Bearer $managedIdentityToken" }

$botAppId = $liveAgent.instance_identity.principal_id
if ([string]::IsNullOrWhiteSpace($botAppId)) {
  throw "Agent '$agentName' has no instance_identity.principal_id."
}

Write-Host "Step 2: deploying the Azure Bot Service."

$displayName = if ($teams.displayName) { $teams.displayName } else { $agentName }
$botResourceName = "$BotName-$agentName"
$messagingEndpoint = "https://$YarpFqdn/teams/$agentName"

$botServiceArmId = az deployment group create `
  --resource-group $ResourceGroup `
  --name "bot-$agentName" `
  --template-file $botTemplate `
  --parameters `
    botName=$botResourceName `
    displayName="$displayName" `
    msaAppId=$botAppId `
    tenantId=$TenantId `
    endpoint=$messagingEndpoint `
    logAnalyticsWorkspaceId=$LogAnalyticsWorkspaceId `
  --query 'properties.outputs.botServiceArmId.value' `
  --output tsv

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($botServiceArmId)) {
  throw "Azure Bot Service deployment failed for '$agentName'."
}

Write-Host "Step 3: enabling the activity protocol."

$protocolBody = @{
  agent_endpoint = @{
    protocol_configuration = @{
      responses = @{}
      activity  = @{}
    }
    authorization_schemes = @(
      @{ type = 'Entra' }
      @{ type = 'BotServiceRbac' }
    )
  }
} | ConvertTo-Json -Depth 10

Invoke-RestMethod `
  -Method Patch `
  -Uri $agentUrl `
  -Headers @{
    Authorization      = "Bearer $managedIdentityToken"
    'Content-Type'     = 'application/merge-patch+json'
    'Foundry-Features' = 'AgentEndpoints=V1Preview'
  } `
  -Body $protocolBody | Out-Null

Write-Host "Step 4: publishing the Microsoft 365 app."

$appVersion = if ($teams.appVersion) { $teams.appVersion } else { '1.0.0' }
$publishBody = @{
  botServiceArmId     = $botServiceArmId
  publishScope        = if ($teams.publishScope) { $teams.publishScope } else { 'Shared' }
  publishAsAutopilot  = $false
  appVersion          = $appVersion
  agentDisplayName    = $displayName
  shortDescription    = $teams.shortDescription
  fullDescription     = $teams.fullDescription
  developerName       = $teams.developerName
  developerWebsiteUrl = $teams.developerWebsiteUrl
  privacyUrl          = $teams.privacyUrl
  termsOfUseUrl       = $teams.termsOfUseUrl
} | ConvertTo-Json -Depth 10

$publishUrl = "$FoundryProjectEndpoint/agents/$agentName/microsoft365/publish?api-version=v1"
$published = $false

for ($attempt = 1; $attempt -le 5 -and -not $published; $attempt++) {
  try {
    $response = Invoke-RestMethod `
      -Method Post `
      -Uri $publishUrl `
      -Headers @{
        Authorization  = "Bearer $PublishAccessToken"
        'Content-Type' = 'application/json'
      } `
      -Body $publishBody

    Write-Host "Published Microsoft 365 title $($response.titleId)."
    $published = $true
  }
  catch {
    $statusCode = if ($_.Exception.Response) {
      [int]$_.Exception.Response.StatusCode
    }
    elseif ($_.Exception.StatusCode) {
      [int]$_.Exception.StatusCode
    }
    else {
      0
    }
    $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { '' }

    if ($detail -match 'version already exists') {
      Write-Host "Microsoft 365 app version '$appVersion' is already published."
      $published = $true
    }
    elseif ($statusCode -in 502, 503, 504 -and $attempt -lt 5) {
      $delay = [Math]::Min(30, [Math]::Pow(2, $attempt))
      Write-Host "Publish returned HTTP $statusCode. Retrying in $delay seconds."
      Start-Sleep -Seconds $delay
    }
    else {
      throw
    }
  }
}

Write-Host "Teams / Microsoft 365 publishing finished for '$agentName'."
