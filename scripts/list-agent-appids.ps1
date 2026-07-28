<#
  List / resolve Foundry agent identity AppIds (for mcp/mcp-policy.json governance)
  ---------------------------------------------------------------------------------
  READ-ONLY. It does NOT change any Azure resource and it does NOT edit the source
  mcp/mcp-policy.json — the allowlist is curated by a human (deny-by-default governance).

  Two modes:
    1. DISCOVERY (default): prints, for each agent, the AppId (instance_identity.client_id) read
       from the Foundry data plane. Handy for eyeballing which identities exist. Needs a REACHABLE
       project endpoint (run on the in-VNet VM for the repo's private project).
    2. RESOLVE (-ResolvePolicyPath <name-only policy>): reads the name-only mcp-policy.json, joins
       each agent NAME to its live AgentIdentity AppId, DROPS any name with no matching identity,
       and emits the RESOLVED (AppId-enriched) policy JSON for apim-mcp-compliance-all.bicep's
       mcpPolicy parameter. Resolution happens here (runtime) because Bicep cannot call Azure to
       look identities up, and they do not exist until the agents are seeded post-provision.

  How RESOLVE finds the AppId (CONTROL PLANE — no private endpoint needed):
    A Foundry agent's runtime identity is an Entra service principal (servicePrincipalType
    'ServiceIdentity') named '<account>-<project>-<agentName>-AgentIdentity'. Its appId is the
    `appid`/`azp` claim the AgenticIdentityToken carries when the agent calls the MCP gateway —
    exactly what apim-mcp-compliance.bicep matches on. RESOLVE reads it from Microsoft Graph via
    `az ad sp list` (a control-plane call), so it runs anywhere the caller can read directory
    objects — the azd host, a GitHub-hosted runner, or the VM — WITHOUT reaching the private
    Foundry data plane. If an agent has more than one such SP (e.g. it was deleted + recreated,
    leaving a stale identity), the NEWEST by createdDateTime is used. If the source policy lists
    agents but NONE resolve, the script THROWS rather than emit a deny-all policy that would revoke
    all access; an intentionally-emptied policy (no agents) DOES emit deny-all so access can be
    revoked on purpose.

  SECURITY / trust model (control-plane resolution):
    The match is (displayName == '<account>-<project>-<name>-AgentIdentity' AND
    servicePrincipalType == 'ServiceIdentity'). Entra display names are NOT unique, so this trusts
    that:
      * 'ServiceIdentity' SPs are provisioned by the Foundry service, not mintable by ordinary
        users (app registrations are type 'Application'; managed identities 'ManagedIdentity').
      * The '<account>-<project>' prefix is a non-forgeable Azure resource name.
    The DEFINITIVE identity is the data-plane instance_identity.client_id (see discovery mode); if
    your threat model includes a hostile tenant member who can create a colliding ServiceIdentity,
    prefer resolving on the in-VNet VM against the data plane instead of this control-plane path.

  Usage:
    # Discovery (data plane; needs a reachable endpoint / the VM):
    ./list-agent-appids.ps1 -FoundryProjectEndpoint https://<acct>.services.ai.azure.com/api/projects/<proj>
    ./list-agent-appids.ps1 -FoundryProjectEndpoint <endpoint> -AgentName 'hello-world-agent,teams-agent'
    # Resolve name-only policy -> resolved policy file (control plane; account+project, no endpoint):
    ./list-agent-appids.ps1 -AccountName <acct> -ProjectName <proj> -ResolvePolicyPath mcp/mcp-policy.json -OutFile resolved.json

  All parameters are [string] (comma-separated for -AgentName) so the script can be shipped to
  the private VM by hooks/vm-run-command.ps1, which invokes `pwsh -File` with string args only.
#>
[CmdletBinding()]
param(
  # DISCOVERY mode only (data plane). Required for discovery; ignored in resolve mode.
  [Parameter(Mandatory = $false)] [string]$FoundryProjectEndpoint = '',
  # RESOLVE mode (control plane): the Foundry account + project names that prefix each agent
  # identity's SP display name ('<account>-<project>-<agentName>-AgentIdentity').
  [Parameter(Mandatory = $false)] [string]$AccountName = '',
  [Parameter(Mandatory = $false)] [string]$ProjectName = '',
  # Optional filter: comma-separated agent names (e.g. 'hello-world-agent,teams-agent').
  # Default: all agents in the project. Ignored in resolve mode (all agents are needed).
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
if (-not [string]::IsNullOrWhiteSpace($FoundryProjectEndpoint)) {
  $FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')
}

# All params are [string] so this script is invokable via hooks/vm-run-command.ps1 (which runs
# it on the private VM through `pwsh -File`, passing only string values). Normalise here:
$resolveMode      = -not [string]::IsNullOrWhiteSpace($ResolvePolicyPath)
# Resolve mode needs EVERY live agent to join against, so the name filter is not applied there.
$agentFilter      = $resolveMode ? @() : @($AgentName -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$rpm              = [int]$RequestsPerMinute
$showBlueprint    = $IncludeBlueprint -eq 'true'

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

# CONTROL-PLANE resolution: read an agent's runtime-identity AppId from Microsoft Graph
# (az ad sp list) instead of the private Foundry data plane, so resolve mode needs no VNet reach.
# The SP is named '<account>-<project>-<agentName>-AgentIdentity' (servicePrincipalType
# 'ServiceIdentity'); its appId is the `appid` claim the AgenticIdentityToken carries.
function Resolve-AgentAppId {
  param([Parameter(Mandatory = $true)][string]$DisplayName)
  $escaped = $DisplayName -replace "'", "''"   # OData single-quote escaping
  $raw = az ad sp list --filter "displayName eq '$escaped'" `
    --query "[?servicePrincipalType=='ServiceIdentity'].{appId:appId,created:createdDateTime}" -o json 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "az ad sp list failed for '$DisplayName' (can the caller read directory objects? a managed identity / OIDC SP needs Directory.Read.All)."
  }
  $matches = @(($raw | ConvertFrom-Json) | Where-Object { $_ -and $_.appId })
  if ($matches.Count -eq 0) { return $null }
  if ($matches.Count -eq 1) { return $matches[0].appId }
  # Duplicates (an agent deleted + recreated leaves a stale SP): the newest is the live one.
  $winner = $matches |
    Sort-Object { if ($_.created) { [datetime]$_.created } else { [datetime]::MinValue } } -Descending |
    Select-Object -First 1
  Write-Host "[resolve] '$DisplayName' has $($matches.Count) ServiceIdentity SPs; using newest (created $($winner.created))."
  return $winner.appId
}

# --- RESOLVE MODE (control plane): name-only policy -> AppId-enriched policy ---
# Join each agent NAME in the source policy to its live AgentIdentity AppId via Graph; DROP names
# with no matching SP (deny-by-default). Emit the resolved policy for apim-mcp-compliance-all.bicep's
# mcpPolicy parameter. Never mutates the source file, never touches the Foundry data plane.
if ($resolveMode) {
  if ([string]::IsNullOrWhiteSpace($AccountName) -or [string]::IsNullOrWhiteSpace($ProjectName)) {
    throw "Resolve mode requires -AccountName and -ProjectName (the Foundry account + project names that prefix each agent identity's display name)."
  }
  if (-not (Test-Path -Path $ResolvePolicyPath)) {
    throw "Resolve policy file not found: '$ResolvePolicyPath'."
  }
  $srcPolicy = Get-Content -Raw -Path $ResolvePolicyPath | ConvertFrom-Json
  $prefix    = "$AccountName-$ProjectName"

  $resolvedServers = foreach ($srv in @($srcPolicy.servers)) {
    $resolvedAgents = foreach ($ag in @($srv.agents)) {
      $displayName = "$prefix-$($ag.name)-AgentIdentity"
      $appId       = Resolve-AgentAppId -DisplayName $displayName
      if ([string]::IsNullOrWhiteSpace($appId)) {
        Write-Host "[resolve] Dropping agent '$($ag.name)' on server '$($srv.name)': no ServiceIdentity SP '$displayName' (denied)."
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
    # yet, or the caller lacks directory read), NOT an intentional lockdown. Refuse to emit a
    # deny-all policy that would revoke ALL access; throwing leaves any previously-applied APIM
    # policy intact. (If the source policy is intentionally emptied, $srcAgentCount is 0 and we
    # correctly emit the empty deny-all policy so access CAN be revoked on purpose.)
    throw "[resolve] Source policy '$ResolvePolicyPath' lists $srcAgentCount agent(s) but NONE resolved (looked for '$prefix-<name>-AgentIdentity'). Refusing to emit a deny-all policy — ensure agents are seeded and the caller can read directory objects."
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

# --- DISCOVERY MODE (data plane) below: requires a reachable endpoint ---
if ([string]::IsNullOrWhiteSpace($FoundryProjectEndpoint)) {
  throw "Discovery mode requires -FoundryProjectEndpoint (a reachable Foundry project endpoint)."
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
