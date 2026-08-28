param(
  [Parameter(Mandatory = $true)] [string]$FoundryProjectEndpoint,
  [Parameter(Mandatory = $true)] [string]$ResourceGroup,
  [Parameter(Mandatory = $true)] [string]$ApimName,
  [Parameter(Mandatory = $true)] [string]$McpWebAppName,
  [Parameter(Mandatory = $true)] [string]$McpAudience,
  [Parameter(Mandatory = $false)] [string]$ApiVersion = '2025-11-15-preview'
)

$ErrorActionPreference = 'Stop'

$policyPath = 'mcp/mcp-policy.json'
if (-not (Test-Path -LiteralPath $policyPath)) {
  throw "MCP policy not found: $policyPath"
}

$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')
$sourcePolicy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json

if ([int]$sourcePolicy.renewalPeriodSeconds -le 0) {
  throw "$policyPath contains an invalid renewalPeriodSeconds value."
}
foreach ($server in @($sourcePolicy.servers)) {
  if ([string]::IsNullOrWhiteSpace($server.name)) {
    throw "$policyPath contains a server without a name."
  }
  foreach ($agent in @($server.agents)) {
    if ([string]::IsNullOrWhiteSpace($agent.name) -or [int]$agent.requestsPerMinute -le 0) {
      throw "$policyPath contains an invalid agent grant for server '$($server.name)'."
    }
  }
}

$token = az account get-access-token `
  --resource https://ai.azure.com `
  --query accessToken `
  --output tsv

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
  throw "Could not acquire a Foundry token."
}

$tenantId = az account show --query tenantId --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tenantId)) {
  throw "Could not resolve the tenant ID."
}

$subscriptionId = az account show --query id --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
  throw "Could not resolve the subscription ID."
}

$headers = @{ Authorization = "Bearer $token" }
$agentAppIds = @{}
$after = $null

do {
  $listUrl = "$FoundryProjectEndpoint/agents?api-version=$ApiVersion&limit=100"
  if ($after) {
    $listUrl += "&after=$after"
  }

  $page = Invoke-RestMethod -Method Get -Uri $listUrl -Headers $headers

  foreach ($agent in @($page.data)) {
    $detail = Invoke-RestMethod `
      -Method Get `
      -Uri "$FoundryProjectEndpoint/agents/$($agent.name)?api-version=$ApiVersion" `
      -Headers $headers

    if ($detail.instance_identity.client_id) {
      $agentAppIds[$agent.name] = $detail.instance_identity.client_id
    }
  }

  $after = if ($page.has_more) { $page.last_id } else { $null }
} while ($after)

$resolvedServers = foreach ($server in @($sourcePolicy.servers)) {
  $resolvedAgents = foreach ($agent in @($server.agents)) {
    $appId = $agentAppIds[$agent.name]
    if (-not $appId) {
      Write-Host "Agent '$($agent.name)' has no live identity and remains denied on '$($server.name)'."
      continue
    }

    [ordered]@{
      name              = $agent.name
      appId             = $appId
      requestsPerMinute = [int]$agent.requestsPerMinute
    }
  }

  [ordered]@{
    name   = $server.name
    agents = @($resolvedAgents)
  }
}

$resolvedPolicy = [ordered]@{
  renewalPeriodSeconds = [int]($sourcePolicy.renewalPeriodSeconds ?? 60)
  servers              = @($resolvedServers)
}

$allowedApplications = @(
  $resolvedServers |
    ForEach-Object { $_.agents } |
    ForEach-Object { $_.appId } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique
)

$resolvedPath = Join-Path ([System.IO.Path]::GetTempPath()) "mcp-policy-$([guid]::NewGuid().ToString('N')).json"
$authPath = Join-Path ([System.IO.Path]::GetTempPath()) "mcp-auth-$([guid]::NewGuid().ToString('N')).json"

try {
  $resolvedPolicy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedPath -Encoding utf8

  Write-Host "Applying the resolved MCP allowlist."

  az deployment group create `
    --resource-group $ResourceGroup `
    --name "mcp-compliance-$(Get-Date -Format 'yyyyMMddHHmmss')" `
    --template-file infra/stages/30-governance/model-gateway/apim-mcp-compliance-all.bicep `
    --parameters `
      apimName=$ApimName `
      mcpAudience=$McpAudience `
      tenantId=$tenantId `
      "mcpPolicy=@$resolvedPath" `
    --output none

  if ($LASTEXITCODE -ne 0) {
    throw "MCP compliance deployment failed."
  }

  $authUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$McpWebAppName/config/authsettingsV2?api-version=2022-03-01"
  $authJson = az rest --method get --url $authUrl --output json
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($authJson)) {
    throw "Could not read MCP App Service authentication settings."
  }

  $auth = $authJson | ConvertFrom-Json
  $validation = $auth.properties.identityProviders.azureActiveDirectory.validation
  if ($null -eq $validation) {
    throw "MCP App Service has no Microsoft Entra validation configuration."
  }

  if ($allowedApplications.Count -gt 0) {
    $validation.defaultAuthorizationPolicy = [pscustomobject]@{
      allowedApplications = @($allowedApplications)
    }
    Write-Host "Allowing $($allowedApplications.Count) agent application(s) through MCP Easy Auth."
  }
  else {
    $validation.defaultAuthorizationPolicy = [pscustomobject]@{
      allowedPrincipals = [pscustomobject]@{}
    }
    Write-Host "No live agent identities resolved; MCP Easy Auth remains deny-all."
  }

  @{ properties = $auth.properties } |
    ConvertTo-Json -Depth 100 |
    Set-Content -LiteralPath $authPath -Encoding utf8

  az rest `
    --method put `
    --url $authUrl `
    --body "@$authPath" `
    --output none

  if ($LASTEXITCODE -ne 0) {
    throw "Could not apply the MCP Easy Auth allowlist."
  }
}
finally {
  Remove-Item -LiteralPath $resolvedPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $authPath -Force -ErrorAction SilentlyContinue
}

Write-Host "MCP APIM and Easy Auth allowlists applied."
