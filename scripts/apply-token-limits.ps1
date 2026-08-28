param(
  [Parameter(Mandatory = $true)] [string]$ResourceGroup,
  [Parameter(Mandatory = $true)] [string]$ApimName,
  [Parameter(Mandatory = $true)] [string]$ApiName,
  [Parameter(Mandatory = $true)] [string]$FoundryAccountName,
  [Parameter(Mandatory = $true)] [string]$FoundryApiPath,
  [Parameter(Mandatory = $false)] [string]$CallerAudience = ''
)

$ErrorActionPreference = 'Stop'

$tenantId = az account show --query tenantId --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tenantId)) {
  throw "Could not resolve the tenant ID."
}

$projectName = ($FoundryApiPath.Trim('/') -split '/')[-1]
if ([string]::IsNullOrWhiteSpace($projectName)) {
  throw "Could not derive the project name from '$FoundryApiPath'."
}

$emailPattern = '^[^@\s"\\<>]+@[^@\s"\\<>]+\.[^@\s"\\<>]+$'
$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$agentRefPattern = '^[A-Za-z0-9._*-]+$'
$quotaPeriods = @('Hourly', 'Daily', 'Weekly', 'Monthly', 'Yearly')
$agents = @()

Get-ChildItem -Path agents -Directory | Sort-Object Name | ForEach-Object {
  $networkPath = Join-Path $_.FullName 'network.json'
  if (-not (Test-Path -LiteralPath $networkPath)) {
    return
  }

  $network = Get-Content -LiteralPath $networkPath -Raw | ConvertFrom-Json
  if ($null -eq $network.tokenLimits) {
    Write-Host "$networkPath has no tokenLimits. The agent remains denied."
    return
  }

  $principals = @($network.tokenLimits.principals)
  if ($principals.Count -eq 0) {
    Write-Host "$networkPath has no token principals. The agent remains denied."
    return
  }

  $agentRef = if ($network.tokenLimits.agentRef) {
    [string]$network.tokenLimits.agentRef
  }
  else {
    $_.Name
  }

  if ($agentRef -notmatch $agentRefPattern) {
    throw "$networkPath contains an invalid agentRef '$agentRef'."
  }

  foreach ($principal in $principals) {
    if (-not $principal.email -and -not $principal.appId) {
      throw "$networkPath contains a principal with neither email nor appId."
    }
    if ($principal.email -and $principal.email -notmatch $emailPattern) {
      throw "$networkPath contains an invalid email '$($principal.email)'."
    }
    if ($principal.appId -and $principal.appId -notmatch $guidPattern) {
      throw "$networkPath contains an invalid appId '$($principal.appId)'."
    }
    if ([int]$principal.tokensPerMinute -le 0) {
      throw "$networkPath contains an invalid tokensPerMinute value."
    }
    if ($principal.PSObject.Properties.Name -contains 'tokenQuota' -and
        [int]$principal.tokenQuota -le 0) {
      throw "$networkPath contains an invalid tokenQuota value."
    }
    if ($principal.tokenQuotaPeriod -and $principal.tokenQuotaPeriod -notin $quotaPeriods) {
      throw "$networkPath contains an invalid tokenQuotaPeriod '$($principal.tokenQuotaPeriod)'."
    }
  }

  $agents += [ordered]@{
    agentRef  = $agentRef
    principals = $principals
  }
}

$policy = @{ agents = $agents }
$policyPath = Join-Path ([System.IO.Path]::GetTempPath()) "agent-limits-$([guid]::NewGuid().ToString('N')).json"

try {
  $policy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $policyPath -Encoding utf8

  Write-Host "Applying token limits for $($agents.Count) agent(s)."

  az deployment group create `
    --resource-group $ResourceGroup `
    --name "foundry-agent-limits-$(Get-Date -Format 'yyyyMMddHHmmss')" `
    --template-file infra/stages/30-governance/model-gateway/apim-foundry-agent-limits.bicep `
    --parameters `
      apimName=$ApimName `
      apiName=$ApiName `
      foundryAccountName=$FoundryAccountName `
      projectName=$projectName `
      tenantId=$tenantId `
      callerAudience=$CallerAudience `
      "agentLimits=@$policyPath" `
    --output none

  if ($LASTEXITCODE -ne 0) {
    throw "Foundry agent token-limit deployment failed."
  }
}
finally {
  Remove-Item -LiteralPath $policyPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Foundry agent token limits applied."
