<#
  Seed Foundry Agents (runs ON the private VM)
  --------------------------------------------
  Executed on the locked-down Linux worker VM (inside the private VNet) by the azd `predeploy`
  hook (hooks/predeploy.ps1), which ships this file over `RunShellScript` and runs it under
  pwsh via the hooks/vm-run-command.ps1 shim. The VM is the only host that can reach the
  Foundry private endpoint, so the seeding logic must run here.

  It acquires a managed-identity token via IMDS and calls the Agents REST API. Re-running is
  safe: a new agent is created if missing; an existing agent gets a fresh version each run
  (POST .../versions) which is then set as the default served version.

  Edit the $agentsToCreate array below to change which agents get seeded.
#>
param(
  [Parameter(Mandatory = $true)]  [string]$FoundryProjectEndpoint,
  [Parameter(Mandatory = $true)]  [string]$ModelDeploymentName,
  [Parameter(Mandatory = $false)] [string]$EnableSecondAgent = 'false',
  [Parameter(Mandatory = $false)] [string]$SecondAgentModel = ''
)
$ErrorActionPreference = 'Stop'

function Get-FoundryToken {
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
    # Some failures still carry the payload on the response stream rather than ErrorDetails.
    try {
      $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
      $body = $reader.ReadToEnd()
    } catch {}
  }
  # PowerShell 7 surfaces the body here instead of on the response stream.
  if ([string]::IsNullOrWhiteSpace($body) -and $ErrorRecord.ErrorDetails) {
    $body = $ErrorRecord.ErrorDetails.Message
  }
  return [pscustomobject]@{ Status = $status; Body = $body }
}

# Invoke a Foundry REST call with exponential backoff. Post-provision propagation delays (the
# Agents capability host / model-gateway connection becoming reachable) surface as transient
# HTTP failures on the first calls after `azd provision`, so retry and print each failure body.
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
      Write-Host "[seed-agents] $Label failed (attempt $attempt/$MaxAttempts): status=$($detail.Status)"
      if (-not [string]::IsNullOrWhiteSpace($detail.Body)) {
        Write-Host "[seed-agents]   response body: $($detail.Body)"
      }
      if ($attempt -eq $MaxAttempts) {
        throw "[seed-agents] $Label failed after $MaxAttempts attempts (last status=$($detail.Status)). See response body above."
      }
      Write-Host "[seed-agents]   retrying in ${delay}s..."
      Start-Sleep -Seconds $delay
      $delay = [Math]::Min($delay * 2, 60)
    }
  }
}

function Get-ExistingAgents {
  param([string]$Token)
  $response = Invoke-FoundryRequest -Label 'list agents' -Request {
    Invoke-RestMethod `
      -Method Get `
      -Uri "$FoundryProjectEndpoint/agents?api-version=2025-11-15-preview" `
      -Headers @{ Authorization = "Bearer $Token" }
  }
  return $response.data
}

function New-Agent {
  param([string]$Token, [string]$Name, [string]$Instructions, [string]$Model)
  $body = @{
    name        = $Name
    description = $Name
    definition  = @{
      kind         = 'prompt'
      model        = $Model
      instructions = $Instructions
    }
  } | ConvertTo-Json -Depth 10 -Compress

  $response = Invoke-FoundryRequest -Label "create agent '$Name'" -Request {
    Invoke-RestMethod `
      -Method Post `
      -Uri "$FoundryProjectEndpoint/agents?api-version=2025-11-15-preview" `
      -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
      -Body $body
  }
  return $response.id
}

# Create a new (auto-incremented) version of an existing agent and return its version string.
function New-AgentVersion {
  param([string]$Token, [string]$Name, [string]$Instructions, [string]$Model)
  $body = @{
    description = $Name
    definition  = @{
      kind         = 'prompt'
      model        = $Model
      instructions = $Instructions
    }
  } | ConvertTo-Json -Depth 10 -Compress

  $response = Invoke-FoundryRequest -Label "create version '$Name'" -Request {
    Invoke-RestMethod `
      -Method Post `
      -Uri "$FoundryProjectEndpoint/agents/$Name/versions?api-version=2025-11-15-preview" `
      -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
      -Body $body
  }
  return $response.version
}

# Point the agent endpoint at a specific version (100% traffic). Merge-patch, so the
# existing protocol_configuration / authorization_schemes (e.g. a Teams-published agent's
# activity protocol) are preserved — only the version selector is changed.
function Set-ServedAgentVersion {
  param([string]$Token, [string]$Name, [string]$Version)
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
      -Uri "$FoundryProjectEndpoint/agents/$Name`?api-version=2025-11-15-preview" `
      -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/merge-patch+json' } `
      -Body $body
  } | Out-Null
}

# Get the highest existing version number for an agent (integer), or $null if none.
function Get-LatestAgentVersion {
  param([string]$Token, [string]$Name)
  $response = Invoke-FoundryRequest -Label "list versions '$Name'" -Request {
    Invoke-RestMethod `
      -Method Get `
      -Uri "$FoundryProjectEndpoint/agents/$Name/versions?api-version=2025-11-15-preview" `
      -Headers @{ Authorization = "Bearer $Token" }
  }
  $versions = @($response.data | ForEach-Object { [int]$_.version })
  if ($versions.Count -eq 0) { return $null }
  return ($versions | Measure-Object -Maximum).Maximum
}

# Update an existing agent: POST the current definition as a new version and make it the
# default served version. The Foundry API de-duplicates identical definitions, so POSTing an
# unchanged definition returns the EXISTING latest version (no new version is created) - a new
# integer version only appears when the definition (model / instructions) actually changed.
# We capture the version before the POST to report which of the two happened.
function Update-Agent {
  param([string]$Token, [string]$Name, [string]$Instructions, [string]$Model)
  $before = Get-LatestAgentVersion -Token $Token -Name $Name
  $newVersion = New-AgentVersion -Token $Token -Name $Name -Instructions $Instructions -Model $Model
  if ($null -ne $before -and [int]$newVersion -eq [int]$before) {
    Write-Host "[seed-agents] Agent '$Name' unchanged - definition identical, still version $newVersion (no new version created)."
  }
  else {
    Write-Host "[seed-agents] Agent '$Name' definition changed -> new version $newVersion (model '$Model')."
  }
  Set-ServedAgentVersion -Token $Token -Name $Name -Version $newVersion
  Write-Host "[seed-agents] Agent '$Name' serving version $newVersion."
}

Write-Host '[seed-agents] Starting...'
Write-Host "[seed-agents] Endpoint: $FoundryProjectEndpoint"

# Normalise: strip trailing slash so /agents never becomes //agents
$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')

$token = Get-FoundryToken
Write-Host '[seed-agents] Token acquired.'

$existing = Get-ExistingAgents -Token $token
$existingNames = $existing | ForEach-Object { $_.name }

# --- Agent definitions ---
# Add more entries here to seed additional agents.
$agentsToCreate = @(
  @{
    Name         = 'hello-world-agent'
    Model        = $ModelDeploymentName
    Instructions = 'You are a helpful AI assistant. Answer questions clearly and concisely.'
  }
)

# Optional second agent routed through the model-gateway (APIM) connection.
# Its model is the "<apim-connection-name>/<exposed-model-name>" reference.
if ($EnableSecondAgent -eq 'true' -and -not [string]::IsNullOrWhiteSpace($SecondAgentModel)) {
  $agentsToCreate += @{
    Name         = 'gateway-model-agent'
    Model        = $SecondAgentModel
    Instructions = 'You are a helpful AI assistant served through the enterprise model gateway. Answer questions clearly and concisely.'
  }
  # The dedicated agent published to Microsoft Teams / M365 (see teamsAgentName /
  # TEAMS_AGENT_NAME). It also routes through the model gateway. Keeping it separate from the
  # demo agents means only this one is surfaced in Teams; the others stay unpublished.
  $agentsToCreate += @{
    Name         = 'teams-agent'
    Model        = $SecondAgentModel
    Instructions = 'You are a helpful AI assistant available in Microsoft Teams, served through the enterprise model gateway. Answer questions clearly and concisely.'
  }
  Write-Host "[seed-agents] Gateway agents ('gateway-model-agent', 'teams-agent') enabled with model '$SecondAgentModel'."
}

foreach ($agentDef in $agentsToCreate) {
  if ($existingNames -contains $agentDef.Name) {
    Write-Host "[seed-agents] Agent '$($agentDef.Name)' exists - checking for updates."
    Update-Agent -Token $token -Name $agentDef.Name -Instructions $agentDef.Instructions -Model $agentDef.Model
  }
  else {
    $id = New-Agent -Token $token -Name $agentDef.Name -Instructions $agentDef.Instructions -Model $agentDef.Model
    Write-Host "[seed-agents] Created '$($agentDef.Name)' -> $id"
  }
}

Write-Host '[seed-agents] Done.'
