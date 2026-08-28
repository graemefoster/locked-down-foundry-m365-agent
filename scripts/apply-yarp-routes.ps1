param(
  [Parameter(Mandatory = $true)] [string]$ResourceGroup,
  [Parameter(Mandatory = $true)] [string]$YarpWebAppName,
  [Parameter(Mandatory = $true)] [string]$FoundryApiPath,
  [Parameter(Mandatory = $true)] [string]$TeamsApiName
)

$ErrorActionPreference = 'Stop'

$routeSegmentPattern = '^[A-Za-z0-9.-]+$'
$desired = [ordered]@{
  'ReverseProxy__Routes__route1__ClusterId'   = 'cluster1'
  'ReverseProxy__Routes__route1__Match__Path' = '/__disabled_no_route__/{**catch-all}'
}

Get-ChildItem -Path agents -Directory | Sort-Object Name | ForEach-Object {
  $networkPath = Join-Path $_.FullName 'network.json'
  if (-not (Test-Path -LiteralPath $networkPath)) {
    return
  }

  $network = Get-Content -LiteralPath $networkPath -Raw | ConvertFrom-Json
  $agentName = $_.Name

  if (($network.exposeToM365 -eq $true -or $network.exposeFoundryApi -eq $true) -and
      $agentName -notmatch $routeSegmentPattern) {
    throw "$networkPath uses an unsafe agent directory name '$agentName'."
  }

  $routeKey = $agentName -replace '-', '_'

  if ($network.exposeToM365 -eq $true) {
    $routeId = "teams_$routeKey"
    $desired["ReverseProxy__Routes__${routeId}__ClusterId"] = 'cluster1'
    $desired["ReverseProxy__Routes__${routeId}__Match__Path"] = "/teams/$agentName"
    $desired["ReverseProxy__Routes__${routeId}__Transforms__0__PathSet"] = "/$TeamsApiName/$agentName"
  }

  if ($network.exposeFoundryApi -eq $true) {
    $routeId = "foundry_$routeKey"
    $desired["ReverseProxy__Routes__${routeId}__ClusterId"] = 'cluster1'
    $desired["ReverseProxy__Routes__${routeId}__Match__Path"] = "/agents/$agentName/{**remainder}"
    $desired["ReverseProxy__Routes__${routeId}__Transforms__0__PathPrefix"] = "/$($FoundryApiPath.Trim('/'))"
  }
}

$currentJson = az webapp config appsettings list `
  --resource-group $ResourceGroup `
  --name $YarpWebAppName `
  --output json

if ($LASTEXITCODE -ne 0) {
  throw "Could not read YARP app settings."
}

$current = $currentJson | ConvertFrom-Json
$settings = @($desired.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })

Write-Host "Applying $($desired.Count) YARP route setting(s)."

az webapp config appsettings set `
  --resource-group $ResourceGroup `
  --name $YarpWebAppName `
  --settings @settings `
  --output none

if ($LASTEXITCODE -ne 0) {
  throw "Could not apply YARP route settings."
}

$staleSettings = @(
  $current |
    Where-Object {
      $_.name -like 'ReverseProxy__Routes__*' -and
      -not $desired.Contains($_.name)
    } |
    ForEach-Object { $_.name }
)

if ($staleSettings.Count -gt 0) {
  Write-Host "Removing $($staleSettings.Count) stale YARP route setting(s)."

  az webapp config appsettings delete `
    --resource-group $ResourceGroup `
    --name $YarpWebAppName `
    --setting-names @staleSettings `
    --output none

  if ($LASTEXITCODE -ne 0) {
    throw "Could not remove stale YARP route settings."
  }
}

Write-Host "YARP routes applied. Unlisted agents remain unreachable."
