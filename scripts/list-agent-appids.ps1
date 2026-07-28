<#
  List / resolve Foundry agent identity AppIds (for mcp/mcp-policy.json governance)
  ---------------------------------------------------------------------------------
  READ-ONLY. It does NOT change any Azure resource and it does NOT edit the source
  mcp/mcp-policy.json — the allowlist is curated by a human (deny-by-default governance).

  Both modes read the AppId from the Foundry DATA PLANE (instance_identity.client_id), so this
  script must run somewhere that can reach the project endpoint — i.e. ON the in-VNet VM for the
  repo's private project. That data-plane value is the DEFINITIVE agent runtime identity: it is
  the `appid`/`azp` claim the AgenticIdentityToken carries when the agent calls the MCP gateway,
  which is exactly what apim-mcp-compliance.bicep matches on.

  Two modes:
    1. DISCOVERY (default): prints, for each agent, the AppId (instance_identity.client_id).
       Handy for eyeballing which identities exist and for producing a paste-ready `agents[]`
       array for mcp/mcp-policy.json.
    2. RESOLVE (-ResolvePolicyPath <name-only policy>): reads the name-only mcp-policy.json, joins
       each agent NAME to its live AppId from the data plane, DROPS any name with no matching /
       identity-less agent, and emits the RESOLVED (AppId-enriched) policy JSON for
       apim-mcp-compliance-all.bicep's mcpPolicy parameter. Resolution happens here (runtime)
       because Bicep cannot call Azure to look identities up, and the identities do not exist
       until the agents are seeded post-provision. If the source policy lists agents but NONE
       resolve, the script THROWS rather than emit a deny-all policy that would revoke all access;
       an intentionally-emptied policy (no agents) DOES emit deny-all so access can be revoked on
       purpose.

  Why the data plane (and not Microsoft Graph):
    An earlier version resolved names via the control plane (`az ad sp list` on the SP display
    name '<account>-<project>-<name>-AgentIdentity'). Entra display names are NOT unique, so that
    trusted a display-name convention. Reading instance_identity.client_id straight from the
    Foundry project is the authoritative source and avoids that trust model — and since MCP
    compliance already runs on the in-VNet VM, the private endpoint is reachable anyway.

  Usage (run on the in-VNet VM, or anywhere the endpoint is reachable):
    # Discovery — print every agent's AppId + a paste-ready policy array:
    ./list-agent-appids.ps1 -FoundryProjectEndpoint https://<acct>.services.ai.azure.com/api/projects/<proj>
    ./list-agent-appids.ps1 -FoundryProjectEndpoint <endpoint> -AgentName 'hello-world-agent,teams-agent'
    # Resolve name-only policy -> resolved policy file:
    ./list-agent-appids.ps1 -FoundryProjectEndpoint <endpoint> -ResolvePolicyPath mcp/mcp-policy.json -OutFile resolved.json

  All parameters are [string] (comma-separated for -AgentName) so the script can be shipped to
  the private VM by hooks/vm-run-command.ps1, which invokes `pwsh -File` with string args only.
#>
[CmdletBinding()]
param(
  # The Foundry project endpoint to read agent identities from (data plane). Required in BOTH
  # modes; must be reachable (run on the in-VNet VM for the repo's private project).
  [Parameter(Mandatory = $false)] [string]$FoundryProjectEndpoint = '',
  # Optional DISCOVERY filter: comma-separated agent names (e.g. 'hello-world-agent,teams-agent').
  # Default: all agents in the project. Ignored in resolve mode (all agents are needed to join).
  [Parameter(Mandatory = $false)] [string]$AgentName = '',
  # Default RPM written into each emitted policy entry (discovery mode only; tune per agent).
  [Parameter(Mandatory = $false)] [string]$RequestsPerMinute = '60',
  # 'true' also prints blueprint.client_id (governs a whole Agent Identity Blueprint family).
  [Parameter(Mandatory = $false)] [string]$IncludeBlueprint = 'false',
  # RESOLVE MODE: path to the name-only mcp-policy.json to resolve into an AppId-enriched policy.
  [Parameter(Mandatory = $false)] [string]$ResolvePolicyPath = '',
  # In resolve mode, write the resolved policy JSON here (recommended, keeps stdout clean).
  # If empty in resolve mode, the resolved JSON is written to stdout.
  [Parameter(Mandatory = $false)] [string]$OutFile = '',
  [Parameter(Mandatory = $false)] [string]$ApiVersion = '2025-11-15-preview'
)
$ErrorActionPreference = 'Stop'

# All params are [string] so this script is invokable via hooks/vm-run-command.ps1 (which runs
# it on the private VM through `pwsh -File`, passing only string values). Normalise here:
$resolveMode   = -not [string]::IsNullOrWhiteSpace($ResolvePolicyPath)
# Resolve mode needs EVERY live agent to join against, so the name filter is not applied there.
$agentFilter   = $resolveMode ? @() : @($AgentName -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$rpm           = [int]$RequestsPerMinute
$showBlueprint = $IncludeBlueprint -eq 'true'

# Both modes hit the data plane, so an endpoint is always required.
if ([string]::IsNullOrWhiteSpace($FoundryProjectEndpoint)) {
  throw "This script requires -FoundryProjectEndpoint (a reachable Foundry project endpoint). Run it on the in-VNet VM for the repo's private project."
}
$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')

# Acquire an https://ai.azure.com token. On the private VM the IMDS managed identity is the
# only option; off-VM we fall back to the signed-in az CLI user.
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

# Enumerate all agents on the project, then read each agent's runtime identity from its detail.
# Returns [pscustomobject]{ name; appId; blueprintId } for every agent (appId may be $null if the
# agent has no runtime identity yet). This is the single data-plane read used by BOTH modes.
function Get-AgentIdentityRows {
  # 1) List agents (OpenAI schema -> results under .data; follow has_more pagination).
  $agents = @()
  $after  = $null
  do {
    $listUri = "$FoundryProjectEndpoint/agents?api-version=$ApiVersion&limit=100"
    if ($after) { $listUri += "&after=$after" }
    $page    = Invoke-RestMethod -Method Get -Uri $listUri -Headers $headers
    $agents += $page.data
    $hasMore = [bool]$page.has_more
    if ($hasMore) { $after = $page.last_id }
  } while ($hasMore)

  # 2) Fetch each agent and pull its identity (instance_identity.client_id) from the detail.
  foreach ($a in $agents) {
    $detail = Invoke-RestMethod -Method Get -Uri "$FoundryProjectEndpoint/agents/$($a.name)?api-version=$ApiVersion" -Headers $headers
    [pscustomobject]@{
      name        = $a.name
      appId       = $detail.instance_identity.client_id
      blueprintId = $detail.blueprint.client_id
    }
  }
}

# --- RESOLVE MODE (data plane): name-only policy -> AppId-enriched policy ---
# Join each agent NAME in the source policy to its live AppId (from the data plane); DROP names
# with no matching / identity-less agent (deny-by-default). Emit the resolved policy for
# apim-mcp-compliance-all.bicep's mcpPolicy parameter. Never mutates the source file.
if ($resolveMode) {
  if (-not (Test-Path -Path $ResolvePolicyPath)) {
    throw "Resolve policy file not found: '$ResolvePolicyPath'."
  }
  $srcPolicy = Get-Content -Raw -Path $ResolvePolicyPath | ConvertFrom-Json

  # Build a name -> AppId lookup from the live project (skip agents with no runtime identity).
  $appIdByName = @{}
  foreach ($row in Get-AgentIdentityRows) {
    if (-not [string]::IsNullOrWhiteSpace($row.appId)) { $appIdByName[$row.name] = $row.appId }
  }

  $resolvedServers = foreach ($srv in @($srcPolicy.servers)) {
    $resolvedAgents = foreach ($ag in @($srv.agents)) {
      $appId = $appIdByName[$ag.name]
      if ([string]::IsNullOrWhiteSpace($appId)) {
        Write-Host "[resolve] Dropping agent '$($ag.name)' on server '$($srv.name)': no live agent identity found (denied)."
        continue
      }
      [ordered]@{ name = $ag.name; appId = $appId; requestsPerMinute = [int]$ag.requestsPerMinute }
    }
    [ordered]@{ name = $srv.name; agents = @($resolvedAgents) }
  }

  $grantedCount  = @($resolvedServers | ForEach-Object { $_.agents } | Where-Object { $_ }).Count
  $srcAgentCount = @(@($srcPolicy.servers) | ForEach-Object { $_.agents } | Where-Object { $_ }).Count
  $serverCount   = @($resolvedServers).Count
  if ($grantedCount -eq 0 -and $srcAgentCount -gt 0) {
    # The source policy DOES list agents but NONE resolved -> this is a failure (agents not seeded
    # yet, or the endpoint unreachable), NOT an intentional lockdown. Refuse to emit a deny-all
    # policy that would revoke ALL access; throwing leaves any previously-applied APIM policy
    # intact. (If the source policy is intentionally emptied, $srcAgentCount is 0 and we correctly
    # emit the empty deny-all policy so access CAN be revoked on purpose.)
    throw "[resolve] Source policy '$ResolvePolicyPath' lists $srcAgentCount agent(s) but NONE resolved against the live project at '$FoundryProjectEndpoint'. Refusing to emit a deny-all policy — ensure the agents are seeded and the endpoint is reachable."
  }

  $resolved = [ordered]@{
    renewalPeriodSeconds = [int]($srcPolicy.renewalPeriodSeconds ?? 60)
    servers              = @($resolvedServers)
  }
  $json = $resolved | ConvertTo-Json -Depth 8
  if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
    Set-Content -Path $OutFile -Value $json -Encoding utf8
    Write-Host "[resolve] Wrote resolved policy to '$OutFile' ($grantedCount agent grant(s) across $serverCount server(s))."
  }
  else {
    Write-Output $json
  }
  return
}

# --- DISCOVERY MODE (data plane): print AppIds + a paste-ready policy array ---
$rows = @(Get-AgentIdentityRows)
if ($agentFilter.Count -gt 0) {
  $rows = @($rows | Where-Object { $agentFilter -contains $_.name })
}
if ($rows.Count -eq 0) {
  throw "No agents found at '$FoundryProjectEndpoint'$(if ($agentFilter.Count) { " matching: $($agentFilter -join ', ')" })."
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
