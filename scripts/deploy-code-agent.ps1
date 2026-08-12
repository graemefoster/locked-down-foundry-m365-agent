<#
  deploy-code-agent.ps1  (runs ON the private VNet self-hosted runner)
  -------------------------------------------------------------------
  CODE (source-zip) deploy for a HOSTED Foundry agent - the alternative to the container-image
  path (create-agent.ps1 + a prebuilt definition.image). Instead of pulling an image from an ACR,
  Foundry receives the `dotnet publish` output as a multipart zip upload (code_configuration) and
  runs it on its managed dotnet runtime. This path never touches an ACR, so it sidesteps the
  private-ACR provisioning issue that blocks the image variant in the locked-down environment.

  It create-or-updates the agent with a single multipart POST: a brand-new agent is created via
  POST /agents (name carried in the metadata part, version 1), and an existing agent gets a new
  version via POST /agents/{name}/versions. (Foundry has no upsert endpoint - POST /agents/{name}
  404s for an agent that does not yet exist - so this mirrors the JSON path in create-agent.ps1,
  choosing the URL from a by-name existence check.) It does NOT route traffic - that stays
  publish-agent.ps1's job (called after this by the workflow).

  The multipart body has two parts, matching the Foundry code-deploy contract:
    * metadata : application/json - the { name, definition, description } object (from agent.yaml)
    * code     : application/zip  - the publish-output zip (binaries at the archive root)
  plus the headers Foundry-Features: HostedAgents=V1Preview, x-ms-agent-name and
  x-ms-code-zip-sha256 (SHA-256 of the zip, integrity check).

  PowerShell 7 (pwsh), cross-platform. Uses the VM managed identity via IMDS (Get-FoundryToken),
  shared with create-agent.ps1 / publish-agent.ps1 through foundry-agent-common.ps1.
#>
param(
  [Parameter(Mandatory = $true)] [string]$MetadataJsonPath,
  [Parameter(Mandatory = $true)] [string]$ZipPath,
  [Parameter(Mandatory = $true)] [string]$FoundryProjectEndpoint,
  [Parameter(Mandatory = $false)][string]$ApiVersion = '2025-11-15-preview'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'foundry-agent-common.ps1')

$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')

if (-not (Test-Path -LiteralPath $MetadataJsonPath)) { throw "[deploy-code-agent] metadata JSON not found: $MetadataJsonPath" }
if (-not (Test-Path -LiteralPath $ZipPath))          { throw "[deploy-code-agent] code zip not found: $ZipPath" }

$metadata = Get-Content -LiteralPath $MetadataJsonPath -Raw | ConvertFrom-Json
$name = $metadata.name
if ([string]::IsNullOrWhiteSpace($name)) { throw "[deploy-code-agent] metadata has no 'name'." }
if ($null -eq $metadata.definition)      { throw "[deploy-code-agent] metadata has no 'definition'." }

$sha = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$zipInfo = Get-Item -LiteralPath $ZipPath
Write-Host "[deploy-code-agent] Endpoint: $FoundryProjectEndpoint (api-version $ApiVersion)"
Write-Host "[deploy-code-agent] Agent   : $name"
Write-Host "[deploy-code-agent] Zip     : $ZipPath ($([math]::Round($zipInfo.Length/1MB,2)) MiB, sha256=$sha)"

$token = Get-FoundryToken
Write-Host '[deploy-code-agent] Token acquired.'

# Foundry has NO create-or-update endpoint: POST /agents/{name} 404s for a brand-new agent
# ("Agent doesn't exist"). Mirror the JSON path (create-agent.ps1) instead — a by-name lookup
# decides between CREATE (POST /agents, name carried in the metadata part) and a new VERSION
# (POST /agents/{name}/versions). An explicit 404 from Get-AgentByName means "absent".
$existingAgent = Get-AgentByName -Token $token -Endpoint $FoundryProjectEndpoint -ApiVersion $ApiVersion -Name $name
if ($null -ne $existingAgent) {
  $uri = "$FoundryProjectEndpoint/agents/$name/versions`?api-version=$ApiVersion"
  Write-Host "[deploy-code-agent] Agent '$name' exists - uploading a new version."
} else {
  $uri = "$FoundryProjectEndpoint/agents`?api-version=$ApiVersion"
  Write-Host "[deploy-code-agent] Agent '$name' does not exist - creating."
}

# Build the multipart body with explicit per-part Content-Types (Invoke-RestMethod -Form cannot set
# the metadata part to application/json), using System.Net.Http (built into PowerShell 7).
$client  = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromMinutes(10)
$content = [System.Net.Http.MultipartFormDataContent]::new()

$metaBytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $MetadataJsonPath).Path)
$metaPart  = [System.Net.Http.ByteArrayContent]::new($metaBytes)
$metaPart.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
$content.Add($metaPart, 'metadata')

$zipBytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ZipPath).Path)
$zipPart  = [System.Net.Http.ByteArrayContent]::new($zipBytes)
$zipPart.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/zip')
$content.Add($zipPart, 'code', 'agent.zip')

$req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
$req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
$req.Headers.Add('Foundry-Features', 'HostedAgents=V1Preview')
$req.Headers.Add('x-ms-agent-name', $name)
$req.Headers.Add('x-ms-code-zip-sha256', $sha)
$req.Content = $content

Write-Host "[deploy-code-agent] Uploading code -> POST $uri"
$resp     = $client.SendAsync($req).GetAwaiter().GetResult()
$respBody = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
if (-not $resp.IsSuccessStatusCode) {
  throw "[deploy-code-agent] upload failed (HTTP $([int]$resp.StatusCode)). Response: $respBody"
}
Write-Host "[deploy-code-agent] Upload accepted (HTTP $([int]$resp.StatusCode))."

# Resolve the version this upload produced (response shape varies: version object vs agent object).
$version = $null
try {
  $doc = $respBody | ConvertFrom-Json
  if ($doc.version)                        { $version = [string]$doc.version }
  elseif ($doc.versions.latest.version)    { $version = [string]$doc.versions.latest.version }
} catch { }
if ([string]::IsNullOrWhiteSpace($version)) {
  $version = [string](Get-LatestAgentVersion -Token $token -Endpoint $FoundryProjectEndpoint -ApiVersion $ApiVersion -Name $name)
}
if ([string]::IsNullOrWhiteSpace($version)) { throw "[deploy-code-agent] Could not resolve the created version." }

Write-Host "[deploy-code-agent] Agent '$name' -> version $version."
if ($env:GITHUB_OUTPUT) {
  "agent-name=$name"       | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
  "agent-version=$version" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}
Write-Host "[deploy-code-agent] Done. agent-name=$name agent-version=$version"
