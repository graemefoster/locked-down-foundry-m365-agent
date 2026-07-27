<#
  List Foundry agent identity AppIds (to populate mcp/mcp-policy.json)
  -------------------------------------------------------------------
  READ-ONLY discovery helper. It does NOT change any Azure resource and it does NOT edit
  mcp/mcp-policy.json — the allowlist is curated by a human (deny-by-default governance).
  This script only prints, for each agent, the AppId you paste into the policy file.

  The value printed is `instance_identity.client_id` from the agent's control-plane
  definition. Because the MCP server connection authenticates with the agent's identity,
  THAT client id is the `appid`/`azp` claim the AgenticIdentityToken carries when the agent
  calls the MCP gateway — i.e. exactly what apim-mcp-compliance.bicep matches on. (The
  sibling `blueprint.client_id` governs a whole Agent Identity Blueprint family instead of a
  single agent; print it too with -IncludeBlueprint if you want to allow at that grain.)

  Where to run it:
    * A REACHABLE project        -> run locally; token comes from `az account get-access-token`.
    * The repo's PRIVATE project -> run ON the locked-down Linux VM (same host seed-agents.ps1
                                    runs on), where the Foundry private endpoint resolves. The
                                    VM managed-identity token is fetched from IMDS automatically.

  Usage:
    ./list-agent-appids.ps1 -FoundryProjectEndpoint https://<acct>.services.ai.azure.com/api/projects/<proj>
    ./list-agent-appids.ps1 -FoundryProjectEndpoint <endpoint> -AgentName 'hello-world-agent,teams-agent'
    ./list-agent-appids.ps1 -FoundryProjectEndpoint <endpoint> -RequestsPerMinute 120 -IncludeBlueprint true

  All parameters are [string] (comma-separated for -AgentName) so the script can be shipped to
  the private VM by hooks/vm-run-command.ps1, which invokes `pwsh -File` with string args only.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]  [string]$FoundryProjectEndpoint,
  # Optional filter: comma-separated agent names (e.g. 'hello-world-agent,teams-agent').
  # Default: all agents in the project.
  [Parameter(Mandatory = $false)] [string]$AgentName = '',
  # Default RPM written into each emitted policy entry (tune per agent afterwards).
  [Parameter(Mandatory = $false)] [string]$RequestsPerMinute = '60',
  # 'true' also prints blueprint.client_id (governs a whole Agent Identity Blueprint family).
  [Parameter(Mandatory = $false)] [string]$IncludeBlueprint = 'false',
  [Parameter(Mandatory = $false)] [string]$ApiVersion = '2025-11-15-preview'
)
$ErrorActionPreference = 'Stop'
$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')

# All params are [string] so this script is invokable via hooks/vm-run-command.ps1 (which runs
# it on the private VM through `pwsh -File`, passing only string values). Normalise here:
$agentFilter      = @($AgentName -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$rpm              = [int]$RequestsPerMinute
$showBlueprint    = $IncludeBlueprint -eq 'true'

# Acquire an https://ai.azure.com token. On the private VM the IMDS managed identity is the
# only option (mirrors seed-agents.ps1); off-VM we fall back to the signed-in az CLI user.
function Get-FoundryToken {
  try {
    $imds = Invoke-RestMethod `
      -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fai.azure.com%2F' `
      -Headers @{ Metadata = 'true' } -Method Get -TimeoutSec 3
    if ($imds.access_token) {
      Write-Host '[list-agent-appids] Using VM managed-identity token (IMDS).'
      return $imds.access_token
    }
  }
  catch {
    Write-Host '[list-agent-appids] IMDS unavailable; falling back to az CLI token.'
  }
  $token = az account get-access-token --resource 'https://ai.azure.com' --query accessToken -o tsv
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    throw "Could not obtain a token. Run 'az login' (off-VM) or run this on the VM (IMDS)."
  }
  return $token
}

$token   = Get-FoundryToken
$headers = @{ Authorization = "Bearer $token" }

# 1) Enumerate agents (OpenAI schema -> results under .data; follow has_more pagination).
$agents = @()
$after  = $null
do {
  $listUri = "$FoundryProjectEndpoint/agents?api-version=$ApiVersion&limit=100"
  if ($after) { $listUri += "&after=$after" }
  $page   = Invoke-RestMethod -Method Get -Uri $listUri -Headers $headers
  $agents += $page.data
  $hasMore = [bool]$page.has_more
  if ($hasMore) { $after = $page.last_id }
} while ($hasMore)
if ($agentFilter.Count -gt 0) {
  $agents = $agents | Where-Object { $agentFilter -contains $_.name }
}
if (-not $agents -or $agents.Count -eq 0) {
  throw "No agents found at '$FoundryProjectEndpoint'$(if ($agentFilter.Count) { " matching: $($agentFilter -join ', ')" })."
}

# 2) Fetch each agent and pull its identity from the control-plane definition.
$rows = foreach ($a in $agents) {
  $detail = Invoke-RestMethod -Method Get -Uri "$FoundryProjectEndpoint/agents/$($a.name)?api-version=$ApiVersion" -Headers $headers
  [pscustomobject]@{
    name         = $a.name
    appId        = $detail.instance_identity.client_id
    blueprintId  = $detail.blueprint.client_id
  }
}

# 3a) Human-readable table.
Write-Host ''
if ($showBlueprint) {
  $rows | Select-Object name, appId, blueprintId | Format-Table -AutoSize | Out-String | Write-Host
} else {
  $rows | Select-Object name, appId | Format-Table -AutoSize | Out-String | Write-Host
}

# 3b) Ready-to-paste `agents[]` array for mcp/mcp-policy.json (curate before committing).
$entries = foreach ($r in $rows) {
  [ordered]@{ name = $r.name; appId = $r.appId; requestsPerMinute = $rpm }
}
Write-Host '--- paste into the "agents" array of mcp/mcp-policy.json (review + set RPM per agent) ---'
Write-Host (@($entries) | ConvertTo-Json -Depth 5 -AsArray)
