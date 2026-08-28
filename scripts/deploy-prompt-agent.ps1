param(
  [Parameter(Mandatory = $true)] [string]$AgentJsonPath,
  [Parameter(Mandatory = $true)] [string]$FoundryProjectEndpoint,
  [Parameter(Mandatory = $false)] [string]$McpServerUrl = '',
  [Parameter(Mandatory = $false)] [string]$ApiVersion = '2025-11-15-preview'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $AgentJsonPath)) {
  throw "Agent JSON not found: $AgentJsonPath"
}

$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')
$agent = Get-Content -LiteralPath $AgentJsonPath -Raw | ConvertFrom-Json
$agentName = $agent.name

if ([string]::IsNullOrWhiteSpace($agentName)) {
  throw "Agent JSON has no 'name': $AgentJsonPath"
}
if ($null -eq $agent.definition) {
  throw "Agent JSON has no 'definition': $AgentJsonPath"
}

$mcpTools = @($agent.definition.tools | Where-Object { $_.type -eq 'mcp' })
if ($mcpTools.Count -gt 0) {
  if ([string]::IsNullOrWhiteSpace($McpServerUrl)) {
    throw "Agent '$agentName' uses MCP, but no MCP server URL was supplied."
  }
  foreach ($tool in $mcpTools) {
    $tool | Add-Member -NotePropertyName server_url -NotePropertyValue $McpServerUrl -Force
  }
}

Write-Host "Deploying prompt agent '$agentName' to $FoundryProjectEndpoint"

$token = az account get-access-token `
  --resource https://ai.azure.com `
  --query accessToken `
  --output tsv

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
  throw "Could not acquire a Foundry token. Run 'az login --identity' first."
}

$headers = @{
  Authorization = "Bearer $token"
  'Content-Type' = 'application/json'
}

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

if ($null -eq $existingAgent) {
  Write-Host "Agent does not exist. Creating it."

  $body = [ordered]@{
    name       = $agentName
    definition = $agent.definition
  }
  if ($null -ne $agent.description) { $body.description = $agent.description }
  if ($null -ne $agent.metadata) { $body.metadata = $agent.metadata }

  $response = Invoke-RestMethod `
    -Method Post `
    -Uri "$FoundryProjectEndpoint/agents?api-version=$ApiVersion" `
    -Headers $headers `
    -Body ($body | ConvertTo-Json -Depth 30)
}
else {
  Write-Host "Agent exists. Creating a version if the definition changed."

  $body = [ordered]@{
    definition = $agent.definition
  }
  if ($null -ne $agent.description) { $body.description = $agent.description }
  if ($null -ne $agent.metadata) { $body.metadata = $agent.metadata }

  $response = Invoke-RestMethod `
    -Method Post `
    -Uri "$FoundryProjectEndpoint/agents/$agentName/versions?api-version=$ApiVersion" `
    -Headers $headers `
    -Body ($body | ConvertTo-Json -Depth 30)
}

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

Write-Host "Agent '$agentName' is serving version $agentVersion."
