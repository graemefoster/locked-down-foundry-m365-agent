param(
  [Parameter(Mandatory = $true)] [string]$AgentJsonPath,
  [Parameter(Mandatory = $true)] [string]$FoundryProjectEndpoint,
  [Parameter(Mandatory = $true)] [string]$AcrName,
  [Parameter(Mandatory = $true)] [string]$ImageRepository,
  [Parameter(Mandatory = $true)] [string]$BuildContext,
  [Parameter(Mandatory = $false)] [string]$Dockerfile = 'Dockerfile',
  [Parameter(Mandatory = $false)] [string]$ApiVersion = '2025-11-15-preview'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $AgentJsonPath)) {
  throw "Agent JSON not found: $AgentJsonPath"
}
if (-not (Test-Path -LiteralPath (Join-Path $BuildContext $Dockerfile))) {
  throw "Dockerfile not found: $(Join-Path $BuildContext $Dockerfile)"
}

$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')
$agent = Get-Content -LiteralPath $AgentJsonPath -Raw | ConvertFrom-Json
$agentName = $agent.name

if ([string]::IsNullOrWhiteSpace($agentName)) {
  throw "Agent JSON has no 'name': $AgentJsonPath"
}

Write-Host "Building the image for '$agentName'."

$loginServer = az acr show --name $AcrName --query loginServer --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($loginServer)) {
  throw "Could not resolve ACR '$AcrName'."
}

$tag = if ($env:GITHUB_SHA) { $env:GITHUB_SHA.Substring(0, 12) } else { 'local' }
$imageReference = "$loginServer/$ImageRepository`:$tag"

az acr login --name $AcrName --output none
if ($LASTEXITCODE -ne 0) {
  throw "Could not sign in to ACR '$AcrName'."
}

$builderName = 'foundry-oci-builder'
docker buildx inspect $builderName *> $null
if ($LASTEXITCODE -eq 0) {
  docker buildx use $builderName
}
else {
  docker buildx create --name $builderName --driver docker-container --use | Out-Null
}

docker buildx build `
  --builder $builderName `
  --provenance=false `
  --output "type=image,name=$imageReference,oci-mediatypes=true,push=true" `
  --tag $imageReference `
  --file (Join-Path $BuildContext $Dockerfile) `
  $BuildContext

if ($LASTEXITCODE -ne 0) {
  throw "Image build failed: $imageReference"
}

$agent.definition.image = $imageReference

Write-Host "Deploying image agent '$agentName' to $FoundryProjectEndpoint"

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
  $body = [ordered]@{ name = $agentName; definition = $agent.definition }
  if ($null -ne $agent.description) { $body.description = $agent.description }
  if ($null -ne $agent.metadata) { $body.metadata = $agent.metadata }

  $response = Invoke-RestMethod `
    -Method Post `
    -Uri "$FoundryProjectEndpoint/agents?api-version=$ApiVersion" `
    -Headers $headers `
    -Body ($body | ConvertTo-Json -Depth 30)
}
else {
  Write-Host "Agent exists. Creating an image version."
  $body = [ordered]@{ definition = $agent.definition }
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

$publishBody = @{
  agent_endpoint = @{
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
} | ConvertTo-Json -Depth 10

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

Write-Host "Agent '$agentName' is serving image version $agentVersion."
