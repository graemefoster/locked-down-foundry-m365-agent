<#
  Shared Foundry Agents helpers (dot-sourced by create-agent.ps1 and publish-agent.ps1)
  ------------------------------------------------------------------------------------
  These functions run ON the private VNet self-hosted runner (the only host that can reach
  the Foundry private endpoint). They acquire a managed-identity token via IMDS and call the
  Agents REST API. This is the single source of truth for the Foundry Agents REST helpers.

  PowerShell 7 (pwsh) and cross-platform: no external modules, no ConvertFrom-Yaml.

  Callers pass the Foundry endpoint and API version through each function's -Endpoint /
  -ApiVersion parameters (see create-agent.ps1 / publish-agent.ps1).
#>
$ErrorActionPreference = 'Stop'

function Get-FoundryToken {
  # Acquire a token for the Foundry data plane (https://ai.azure.com) from the VM managed
  # identity via IMDS. We use IMDS directly rather than the Azure CLI because the self-hosted
  # runner service can hold a stale PATH in which `az` is not resolvable.
  $response = Invoke-RestMethod `
    -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fai.azure.com%2F' `
    -Headers @{ Metadata = 'true' } `
    -Method Get
  return $response.access_token
}

# Extract the HTTP status code + response body from a terminating Invoke-RestMethod error.
# The bare WebException message ("(400) Bad Request") hides the real reason; the Foundry API
# returns a JSON { error: { code, message } } body that explains exactly what was rejected.
function Get-HttpErrorDetail {
  param($ErrorRecord)
  $status = 'n/a'
  $body   = ''
  $resp   = $ErrorRecord.Exception.Response
  if ($resp) {
    try { $status = [int]$resp.StatusCode } catch {}
    try {
      $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
      $body = $reader.ReadToEnd()
    } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($body) -and $ErrorRecord.ErrorDetails) {
    $body = $ErrorRecord.ErrorDetails.Message
  }
  return [pscustomobject]@{ Status = $status; Body = $body }
}

# Invoke a Foundry REST call with exponential backoff. Post-provision propagation delays surface
# as transient HTTP failures on the first calls, so retry and print each failure body.
function Invoke-FoundryRequest {
  param(
    [string]$Label,
    [scriptblock]$Request,
    [int]$MaxAttempts = 5,
    [int]$InitialDelaySeconds = 5
  )
  $delay = $InitialDelaySeconds
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      return & $Request
    }
    catch {
      $detail = Get-HttpErrorDetail -ErrorRecord $_
      Write-Host "[foundry] $Label failed (attempt $attempt/$MaxAttempts): status=$($detail.Status)"
      if (-not [string]::IsNullOrWhiteSpace($detail.Body)) {
        Write-Host "[foundry]   response body: $($detail.Body)"
      }
      if ($attempt -eq $MaxAttempts) {
        throw "[foundry] $Label failed after $MaxAttempts attempts (last status=$($detail.Status)). See response body above."
      }
      Write-Host "[foundry]   retrying in ${delay}s..."
      Start-Sleep -Seconds $delay
      $delay = [Math]::Min($delay * 2, 60)
    }
  }
}

function Get-ExistingAgents {
  param([string]$Token, [string]$Endpoint, [string]$ApiVersion)
  $response = Invoke-FoundryRequest -Label 'list agents' -Request {
    Invoke-RestMethod `
      -Method Get `
      -Uri "$Endpoint/agents?api-version=$ApiVersion" `
      -Headers @{ Authorization = "Bearer $Token" }
  }
  # Foundry Agents API returns agents under .data (OpenAI schema), not .value.
  return $response.data
}

# Create a brand-new agent. $Definition/$Metadata are objects (from the parsed manifest).
# Returns the created agent's latest version string.
function New-Agent {
  param(
    [string]$Token, [string]$Endpoint, [string]$ApiVersion,
    [string]$Name, [string]$Description, $Definition, $Metadata
  )
  $payload = [ordered]@{ name = $Name; definition = $Definition }
  if ($null -ne $Description) { $payload.description = $Description }
  if ($null -ne $Metadata)    { $payload.metadata    = $Metadata }
  $body = $payload | ConvertTo-Json -Depth 30 -Compress

  $response = Invoke-FoundryRequest -Label "create agent '$Name'" -Request {
    Invoke-RestMethod `
      -Method Post `
      -Uri "$Endpoint/agents?api-version=$ApiVersion" `
      -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
      -Body $body
  }
  if ($response.versions -and $response.versions.latest) { return [string]$response.versions.latest.version }
  if ($response.version) { return [string]$response.version }
  return $null
}

# Create a new (auto-incremented) version of an existing agent; return its version string.
# The API de-duplicates identical definitions, so POSTing an unchanged definition returns the
# EXISTING latest version (no new version created).
function New-AgentVersion {
  param(
    [string]$Token, [string]$Endpoint, [string]$ApiVersion,
    [string]$Name, [string]$Description, $Definition, $Metadata
  )
  $payload = [ordered]@{ definition = $Definition }
  if ($null -ne $Description) { $payload.description = $Description }
  if ($null -ne $Metadata)    { $payload.metadata    = $Metadata }
  $body = $payload | ConvertTo-Json -Depth 30 -Compress

  $response = Invoke-FoundryRequest -Label "create version '$Name'" -Request {
    Invoke-RestMethod `
      -Method Post `
      -Uri "$Endpoint/agents/$Name/versions?api-version=$ApiVersion" `
      -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
      -Body $body
  }
  return [string]$response.version
}

# Get the highest existing version number for an agent (integer), or $null if none.
function Get-LatestAgentVersion {
  param([string]$Token, [string]$Endpoint, [string]$ApiVersion, [string]$Name)
  $response = Invoke-FoundryRequest -Label "list versions '$Name'" -Request {
    Invoke-RestMethod `
      -Method Get `
      -Uri "$Endpoint/agents/$Name/versions?api-version=$ApiVersion" `
      -Headers @{ Authorization = "Bearer $Token" }
  }
  $versions = @($response.data | ForEach-Object { [int]$_.version })
  if ($versions.Count -eq 0) { return $null }
  return ($versions | Measure-Object -Maximum).Maximum
}

# Return all existing version numbers for an agent as ints, sorted DESCENDING (highest
# first), or an empty array if the agent has no versions. Used by the nightly eval
# workflow to pick the latest version and the one before it (baseline) for comparison.
function Get-AgentVersionsDescending {
  param([string]$Token, [string]$Endpoint, [string]$ApiVersion, [string]$Name)
  $response = Invoke-FoundryRequest -Label "list versions '$Name'" -Request {
    Invoke-RestMethod `
      -Method Get `
      -Uri "$Endpoint/agents/$Name/versions?api-version=$ApiVersion" `
      -Headers @{ Authorization = "Bearer $Token" }
  }
  $versions = @($response.data | ForEach-Object { [int]$_.version })
  if ($versions.Count -eq 0) { return @() }
  return @($versions | Sort-Object -Descending)
}

# Point the agent endpoint at a specific version (100% traffic). Merge-patch, so any existing
# protocol_configuration / authorization_schemes (e.g. a Teams-published agent) are preserved.
function Set-ServedAgentVersion {
  param([string]$Token, [string]$Endpoint, [string]$ApiVersion, [string]$Name, [string]$Version)
  $body = @{
    agent_endpoint = @{
      version_selector = @{
        version_selection_rules = @(
          @{ agent_version = $Version; traffic_percentage = 100; type = 'FixedRatio' }
        )
      }
    }
  } | ConvertTo-Json -Depth 10 -Compress

  Invoke-FoundryRequest -Label "set served version '$Name'->$Version" -Request {
    Invoke-RestMethod `
      -Method Patch `
      -Uri "$Endpoint/agents/$Name`?api-version=$ApiVersion" `
      -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/merge-patch+json' } `
      -Body $body
  } | Out-Null
}
