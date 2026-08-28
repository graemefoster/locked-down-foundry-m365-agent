$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "agent-automation-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot | Out-Null

function Assert-True {
  param(
    [Parameter(Mandatory = $true)] [bool]$Condition,
    [Parameter(Mandatory = $true)] [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function New-NotFoundException {
  $exception = [System.Exception]::new('Not found')
  $exception | Add-Member -NotePropertyName StatusCode -NotePropertyValue 404
  return $exception
}

try {
  $global:LASTEXITCODE = 0
  $global:AzCalls = [System.Collections.Generic.List[string]]::new()
  $global:CurlCalls = [System.Collections.Generic.List[string]]::new()
  $global:RestCalls = [System.Collections.Generic.List[object]]::new()
  $global:UploadedMetadata = ''
  $global:PromptScenario = 'create'
  $global:VersionResponse = @{ version = '2' }

  function global:az {
    $command = $args -join ' '
    $global:AzCalls.Add($command)
    $global:LASTEXITCODE = 0

    if ($command -match 'account get-access-token') {
      return 'fixture-token'
    }
    if ($command -match 'account show') {
      return '00000000-0000-0000-0000-000000000001'
    }
    if ($command -match 'acr show') {
      return 'fixture.azurecr.io'
    }
    if ($command -match 'webapp config appsettings list') {
      return '[{"name":"ReverseProxy__Routes__old__Match__Path","value":"/old"}]'
    }
  }

  function global:docker {
    $global:LASTEXITCODE = 0
    if (($args -join ' ') -match 'buildx inspect') {
      return 'fixture-builder'
    }
  }

  function global:curl {
    $global:CurlCalls.Add(($args -join ' '))
    $metadataArgument = @($args | Where-Object { $_ -like 'metadata=@*' })[0]
    if ($metadataArgument) {
      $metadataPath = ($metadataArgument -replace '^metadata=@', '') -replace ';type=application/json$', ''
      $global:UploadedMetadata = Get-Content -LiteralPath $metadataPath -Raw
    }
    $global:LASTEXITCODE = 0
    return '{"version":"3"}'
  }

  function global:Invoke-RestMethod {
    param(
      [string]$Method,
      [string]$Uri,
      [hashtable]$Headers,
      [string]$Body
    )

    $global:RestCalls.Add([pscustomobject]@{
      Method = $Method
      Uri     = $Uri
      Headers = $Headers
      Body    = $Body
    })

    if ($Uri -match '/agents/fixture-agent\?') {
      if ($Method -eq 'Get' -and $global:PromptScenario -eq 'create') {
        throw (New-NotFoundException)
      }
      if ($Method -eq 'Get') {
        return @{ name = 'fixture-agent' }
      }
      return @{}
    }
    if ($Uri -match '/agents\?' -and $Method -eq 'Post') {
      return @{ version = '1' }
    }
    if ($Uri -match '/versions\?' -and $Method -eq 'Post') {
      return $global:VersionResponse
    }
    if ($Uri -match '/versions\?' -and $Method -eq 'Get') {
      return @{ data = @(@{ version = '4' }) }
    }
    if ($Uri -match '/agents\?' -and $Method -eq 'Get') {
      return @{ data = @(); has_more = $false }
    }

    throw "Unexpected REST call: $Method $Uri"
  }

  $promptAgentPath = Join-Path $tempRoot 'prompt-agent.json'
  @{
    name       = 'fixture-agent'
    definition = @{
      kind  = 'prompt'
      model = 'fixture-model'
      tools = @(
        @{
          type       = 'mcp'
          server_url = ''
        }
      )
    }
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $promptAgentPath

  & "$repositoryRoot/scripts/deploy-prompt-agent.ps1" `
    -AgentJsonPath $promptAgentPath `
    -FoundryProjectEndpoint 'https://fixture.services.ai.azure.com/api/projects/project' `
    -McpServerUrl 'https://fixture.example/mcp'

  $createCall = @($global:RestCalls | Where-Object {
      $_.Method -eq 'Post' -and $_.Uri -match '/agents\?'
    })
  $createPublish = @($global:RestCalls | Where-Object { $_.Method -eq 'Patch' })
  Assert-True ($createCall.Count -eq 1) 'Prompt create did not issue exactly one create request.'
  Assert-True ($createCall[0].Body -match 'https://fixture.example/mcp') 'Prompt create did not inject the MCP URL.'
  Assert-True ($createPublish[0].Body -match '"agent_version": "1"') 'Prompt create did not serve version 1.'

  $global:PromptScenario = 'version'
  $global:RestCalls.Clear()

  & "$repositoryRoot/scripts/deploy-prompt-agent.ps1" `
    -AgentJsonPath $promptAgentPath `
    -FoundryProjectEndpoint 'https://fixture.services.ai.azure.com/api/projects/project' `
    -McpServerUrl 'https://fixture.example/mcp'

  $versionCall = @($global:RestCalls | Where-Object {
      $_.Method -eq 'Post' -and $_.Uri -match '/versions\?'
    })
  $versionPublish = @($global:RestCalls | Where-Object { $_.Method -eq 'Patch' })
  Assert-True ($versionCall.Count -eq 1) 'Prompt update did not issue exactly one version request.'
  Assert-True ($versionPublish[0].Body -match '"agent_version": "2"') 'Prompt update did not serve version 2.'
  Write-Host 'PASS prompt create, version, and served-version routing'

  $codeAgentPath = Join-Path $tempRoot 'code-agent.json'
  $zipPath = Join-Path $tempRoot 'agent.zip'
  @{
    name       = 'fixture-agent'
    definition = @{
      kind = 'hosted'
      code_configuration = @{
        runtime     = 'dotnet_10'
        entry_point = @('dotnet', 'fixture.dll')
      }
      environment_variables = @{
        FOUNDRY_PROJECT_ENDPOINT = ''
      }
    }
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $codeAgentPath
  [System.IO.File]::WriteAllBytes($zipPath, [byte[]](1, 2, 3))

  $global:PromptScenario = 'version'
  $global:CurlCalls.Clear()
  $global:RestCalls.Clear()
  $global:UploadedMetadata = ''

  & "$repositoryRoot/scripts/deploy-code-agent.ps1" `
    -AgentJsonPath $codeAgentPath `
    -ZipPath $zipPath `
    -FoundryProjectEndpoint 'https://fixture.services.ai.azure.com/api/projects/project'

  Assert-True ($global:CurlCalls.Count -eq 1) 'Code deploy did not issue exactly one multipart upload.'
  Assert-True ($global:CurlCalls[0] -match 'metadata=@.*;type=application/json') 'Code deploy omitted the JSON multipart type.'
  Assert-True ($global:CurlCalls[0] -match 'code=@.*;type=application/zip') 'Code deploy omitted the zip multipart type.'
  Assert-True (
    $global:UploadedMetadata -match 'https://fixture.services.ai.azure.com/api/projects/project'
  ) 'Code deploy did not inject FOUNDRY_PROJECT_ENDPOINT into the hosted agent metadata.'
  Assert-True (
    @($global:RestCalls | Where-Object {
        $_.Method -eq 'Patch' -and $_.Body -match '"agent_version": "3"'
      }).Count -eq 1
  ) 'Code deploy did not serve the uploaded version.'
  Write-Host 'PASS source-zip multipart upload and endpoint injection'

  $imageAgentPath = Join-Path $tempRoot 'image-agent.json'
  $buildContext = Join-Path $tempRoot 'image-build'
  New-Item -ItemType Directory -Path $buildContext | Out-Null
  'FROM scratch' | Set-Content -LiteralPath (Join-Path $buildContext 'Dockerfile')
  @{
    name       = 'fixture-agent'
    definition = @{
      kind  = 'hosted'
      image = ''
    }
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $imageAgentPath

  $global:PromptScenario = 'version'
  $global:VersionResponse = @{}
  $global:RestCalls.Clear()
  $env:GITHUB_SHA = '0123456789abcdef0123456789abcdef01234567'

  & "$repositoryRoot/scripts/deploy-image-agent.ps1" `
    -AgentJsonPath $imageAgentPath `
    -FoundryProjectEndpoint 'https://fixture.services.ai.azure.com/api/projects/project' `
    -AcrName 'fixture' `
    -ImageRepository 'agents/fixture-agent' `
    -BuildContext $buildContext

  Assert-True (
    @($global:RestCalls | Where-Object {
        $_.Method -eq 'Post' -and $_.Body -match 'fixture\.azurecr\.io/agents/fixture-agent:0123456789ab'
      }).Count -eq 1
  ) 'Image deploy did not inject the pushed image reference.'
  Assert-True (
    @($global:RestCalls | Where-Object {
        $_.Method -eq 'Patch' -and $_.Body -match '"agent_version": "4"'
      }).Count -eq 1
  ) 'Image deploy did not resolve and serve the fallback version.'
  Write-Host 'PASS image reference injection and version fallback'

  $teamsDirectory = Join-Path $tempRoot 'teams-disabled'
  New-Item -ItemType Directory -Path $teamsDirectory | Out-Null
  @{ name = 'fixture-agent'; definition = @{ kind = 'prompt' } } |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath (Join-Path $teamsDirectory 'agent.json')
  @{ exposeToM365 = $false } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $teamsDirectory 'network.json')
  @{ displayName = 'Fixture agent' } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $teamsDirectory 'teams.json')

  $global:RestCalls.Clear()
  & "$repositoryRoot/scripts/publish-teams.ps1" `
    -AgentDirectory $teamsDirectory `
    -FoundryProjectEndpoint 'https://fixture.services.ai.azure.com/api/projects/project' `
    -ResourceGroup 'fixture-rg' `
    -YarpFqdn 'fixture.example' `
    -TenantId '00000000-0000-0000-0000-000000000001' `
    -BotName 'fixture-bot' `
    -PublishAccessToken 'fixture-user-token'

  Assert-True ($global:RestCalls.Count -eq 0) 'Teams-disabled publishing made a REST request.'
  Write-Host 'PASS Teams-disabled short-circuit'

  $policyRoot = Join-Path $tempRoot 'empty-policy'
  New-Item -ItemType Directory -Path (Join-Path $policyRoot 'mcp') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $policyRoot 'agents') -Force | Out-Null
  @{ renewalPeriodSeconds = 60; servers = @() } |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath (Join-Path $policyRoot 'mcp/mcp-policy.json')

  $global:RestCalls.Clear()
  $global:AzCalls.Clear()
  Push-Location $policyRoot
  try {
    & "$repositoryRoot/scripts/apply-mcp-policy.ps1" `
      -FoundryProjectEndpoint 'https://fixture.services.ai.azure.com/api/projects/project' `
      -ResourceGroup 'fixture-rg' `
      -ApimName 'fixture-apim' `
      -McpAudience 'api://fixture'
  }
  finally {
    Pop-Location
  }

  Assert-True (
    @($global:AzCalls | Where-Object { $_ -match 'apim-mcp-compliance-all\.bicep' }).Count -eq 1
  ) 'Empty MCP policy did not deploy the deny-all policy.'
  Write-Host 'PASS empty MCP policy applies deny-all'

  $routeRoot = Join-Path $tempRoot 'routes'
  $routeAgentDirectory = Join-Path $routeRoot 'agents/fixture-agent'
  New-Item -ItemType Directory -Path $routeAgentDirectory -Force | Out-Null
  @{
    exposeToM365     = $true
    exposeFoundryApi = $true
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $routeAgentDirectory 'network.json')

  $global:AzCalls.Clear()
  Push-Location $routeRoot
  try {
    & "$repositoryRoot/scripts/apply-yarp-routes.ps1" `
      -ResourceGroup 'fixture-rg' `
      -YarpWebAppName 'fixture-yarp' `
      -FoundryApiPath 'foundry/accounts/account/projects/project' `
      -TeamsApiName 'teams-api'
  }
  finally {
    Pop-Location
  }

  $setIndex = $global:AzCalls.FindIndex({ param($call) $call -match 'appsettings set' })
  $deleteIndex = $global:AzCalls.FindIndex({ param($call) $call -match 'appsettings delete' })
  $setCall = $global:AzCalls[$setIndex]
  Assert-True ($setIndex -ge 0) 'YARP routes were not applied.'
  Assert-True ($deleteIndex -gt $setIndex) 'Stale YARP routes were removed before desired routes were applied.'
  Assert-True ($setCall -match '/teams/fixture-agent') 'The unsuffixed Teams route was not applied.'
  Assert-True ($setCall -match '/agents/fixture-agent/\{\*\*remainder\}') 'The unsuffixed Foundry route was not applied.'
  Write-Host 'PASS YARP apply-before-prune ordering'
}
finally {
  Remove-Item Function:\az -ErrorAction SilentlyContinue
  Remove-Item Function:\curl -ErrorAction SilentlyContinue
  Remove-Item Function:\docker -ErrorAction SilentlyContinue
  Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
  Remove-Item Env:\GITHUB_SHA -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'All agent automation smoke tests passed.'
