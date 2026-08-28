param(
  [Parameter(Mandatory = $true)] [string]$AgentJsonPath,
  [Parameter(Mandatory = $true)] [string]$ZipPath,
  [Parameter(Mandatory = $true)] [string]$FoundryProjectEndpoint,
  [Parameter(Mandatory = $false)] [string]$ApiVersion = '2025-11-15-preview'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $AgentJsonPath)) {
  throw "Agent JSON not found: $AgentJsonPath"
}
if (-not (Test-Path -LiteralPath $ZipPath)) {
  throw "Agent zip not found: $ZipPath"
}

$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')
$agent = Get-Content -LiteralPath $AgentJsonPath -Raw | ConvertFrom-Json
$agentName = $agent.name

if ([string]::IsNullOrWhiteSpace($agentName)) {
  throw "Agent JSON has no 'name': $AgentJsonPath"
}
if ($null -eq $agent.definition.code_configuration) {
  throw "Agent '$agentName' has no definition.code_configuration."
}
if ($agent.definition.environment_variables.PSObject.Properties.Name -contains 'FOUNDRY_PROJECT_ENDPOINT') {
  $agent.definition.environment_variables.FOUNDRY_PROJECT_ENDPOINT = $FoundryProjectEndpoint
}

Write-Host "Deploying code agent '$agentName' to $FoundryProjectEndpoint"

$token = az account get-access-token `
  --resource https://ai.azure.com `
  --query accessToken `
  --output tsv

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
  throw "Could not acquire a Foundry token. Run 'az login --identity' first."
}

$headers = @{ Authorization = "Bearer $token" }
$agentUrl = "$FoundryProjectEndpoint/agents/$agentName`?api-version=$ApiVersion"
$existingAgent = $null

try {
  $existingAgent = Invoke-RestMethod -Method Get -Uri $agentUrl -Headers $headers
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
  if ($statusCode -ne 404) {
    throw
  }
}

$uploadUrl = if ($null -eq $existingAgent) {
  Write-Host "Agent does not exist. Creating it with the code package."
  "$FoundryProjectEndpoint/agents?api-version=$ApiVersion"
}
else {
  Write-Host "Agent exists. Uploading a new code version."
  "$FoundryProjectEndpoint/agents/$agentName/versions?api-version=$ApiVersion"
}

$metadata = [ordered]@{
  name       = $agentName
  definition = $agent.definition
}
if ($null -ne $agent.description) { $metadata.description = $agent.description }
if ($null -ne $agent.metadata) { $metadata.metadata = $agent.metadata }

$metadataJson = $metadata | ConvertTo-Json -Depth 30
$zipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$metadataPath = Join-Path ([System.IO.Path]::GetTempPath()) "agent-metadata-$([guid]::NewGuid().ToString('N')).json"

try {
  $metadataJson | Set-Content -LiteralPath $metadataPath -Encoding utf8

  $uploadBody = curl `
    --fail-with-body `
    --silent `
    --show-error `
    --request POST `
    --header "Authorization: Bearer $token" `
    --header 'Foundry-Features: HostedAgents=V1Preview' `
    --header "x-ms-agent-name: $agentName" `
    --header "x-ms-code-zip-sha256: $zipHash" `
    --form "metadata=@$metadataPath;type=application/json" `
    --form "code=@$((Resolve-Path -LiteralPath $ZipPath).Path);type=application/zip" `
    $uploadUrl

  if ($LASTEXITCODE -ne 0) {
    throw "Code upload failed for '$agentName'."
  }
}
finally {
  Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
}

$response = $uploadBody | ConvertFrom-Json
$agentVersion = if ($response.version) {
  [string]$response.version
}
elseif ($response.versions.latest.version) {
  [string]$response.versions.latest.version
}
else {
  $versions = Invoke-RestMethod `
    -Method Get `
    -Uri "$FoundryProjectEndpoint/agents/$agentName/versions?api-version=$ApiVersion" `
    -Headers $headers
  [string](@($versions.data.version | ForEach-Object { [int]$_ }) | Measure-Object -Maximum).Maximum
}

if ([string]::IsNullOrWhiteSpace($agentVersion)) {
  throw "Could not resolve the version created for '$agentName'."
}

# Serve the new version AND assert the endpoint protocol/authorization configuration from the
# manifest in a single agent_endpoint merge-patch. Declaring 'agent_endpoint' in agent.yaml (e.g.
# the 'activity' protocol + BotServiceRbac for a Teams agent) means publishing no longer has to
# patch the protocol on separately.
$agentEndpoint = [ordered]@{
  version_selector = @{
    version_selection_rules = @(
      @{
        agent_version      = $agentVersion
        traffic_percentage = 100
        type               = 'FixedRatio'
      }
    )
  }
}
if ($null -ne $agent.agent_endpoint) {
  if ($null -ne $agent.agent_endpoint.protocol_configuration) {
    $agentEndpoint.protocol_configuration = $agent.agent_endpoint.protocol_configuration
  }
  if ($null -ne $agent.agent_endpoint.authorization_schemes) {
    $agentEndpoint.authorization_schemes = $agent.agent_endpoint.authorization_schemes
  }
}

$publishBody = @{ agent_endpoint = $agentEndpoint } | ConvertTo-Json -Depth 10

Invoke-RestMethod `
  -Method Patch `
  -Uri $agentUrl `
  -Headers @{
    Authorization  = "Bearer $token"
    'Content-Type' = 'application/merge-patch+json'
  } `
  -Body $publishBody | Out-Null

if ($env:GITHUB_OUTPUT) {
  "agent-name=$agentName" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
  "agent-version=$agentVersion" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}

Write-Host "Agent '$agentName' is serving code version $agentVersion."
