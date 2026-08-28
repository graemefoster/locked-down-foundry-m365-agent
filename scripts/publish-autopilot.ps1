param(
  [Parameter(Mandatory = $true)] [string]$AgentDirectory,
  [Parameter(Mandatory = $true)] [string]$FoundryProjectEndpoint,
  [Parameter(Mandatory = $true)] [string]$PublishAccessToken
)

$ErrorActionPreference = 'Stop'

$agentPath = Join-Path $AgentDirectory 'agent.yaml'
$autopilotPath = Join-Path $AgentDirectory 'autopilot.json'

foreach ($path in @($agentPath, $autopilotPath)) {
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Required file not found: $path"
  }
}

$agentName = (& yq -r '.name' $agentPath)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($agentName)) {
  throw "Could not read the agent name from '$agentPath' (is yq installed on the runner?)."
}
if ([string]::IsNullOrWhiteSpace($PublishAccessToken)) {
  throw "A delegated user token is required for Microsoft 365 publishing."
}

$autopilot = Get-Content -LiteralPath $autopilotPath -Raw | ConvertFrom-Json
$displayName = if ($autopilot.displayName) { $autopilot.displayName } else { $agentName }
$appVersion = if ($autopilot.appVersion) { $autopilot.appVersion } else { '1.0.0' }

$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')
$agentUrl = "$FoundryProjectEndpoint/agents/$agentName`?api-version=2025-11-15-preview"
$liveAgent = Invoke-RestMethod `
  -Method Get `
  -Uri $agentUrl `
  -Headers @{ Authorization = "******" }

$blueprintClientId = $liveAgent.versions.latest.blueprint.client_id
if ([string]::IsNullOrWhiteSpace($blueprintClientId)) {
  throw "Agent '$agentName' has no latest blueprint client ID."
}

$publishBody = [ordered]@{
  agentDisplayName         = $displayName
  publishAsAutopilot       = $true
  publishScope             = if ($autopilot.publishScope) { $autopilot.publishScope } else { 'Tenant' }
  appVersion               = $appVersion
  canRespondWithoutMention = $autopilot.canRespondWithoutMention -eq $true
  shortDescription         = $autopilot.shortDescription
  fullDescription          = $autopilot.fullDescription
  developerName            = $autopilot.developerName
  developerWebsiteUrl      = $autopilot.developerWebsiteUrl
  privacyUrl               = $autopilot.privacyUrl
  termsOfUseUrl            = $autopilot.termsOfUseUrl
  useAgenticUserTemplate   = $true
  agenticUserTemplate      = [ordered]@{
    Id                       = 'digitalWorkerTemplate'
    File                     = 'agenticUserTemplateManifest.json'
    SchemaVersion            = '0.1.0-preview'
    AgentIdentityBlueprintId = $blueprintClientId
    CommunicationProtocol    = 'activityProtocol'
  }
}
if ($null -ne $autopilot.optionalPermissionScopes) {
  $publishBody.optionalPermissionScopes = @($autopilot.optionalPermissionScopes)
}

$publishUrl = "$FoundryProjectEndpoint/agents/$agentName/microsoft365/publish?api-version=2025-11-15-preview"
$publishJson = $publishBody | ConvertTo-Json -Depth 10
$published = $false

Write-Host "Publishing Autopilot '$agentName' to Microsoft 365."

for ($attempt = 1; $attempt -le 5 -and -not $published; $attempt++) {
  try {
    $response = Invoke-RestMethod `
      -Method Post `
      -Uri $publishUrl `
      -Headers @{
        Authorization  = "Bearer $PublishAccessToken"
        'Content-Type' = 'application/json'
        Accept         = 'application/json'
      } `
      -Body $publishJson

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
      Write-Host "Microsoft 365 Autopilot version '$appVersion' is already published."
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

Write-Host "Autopilot publishing finished for '$agentName'."
