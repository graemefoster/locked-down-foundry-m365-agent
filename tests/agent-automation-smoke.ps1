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
  $global:McpPolicyScenario = 'empty'
  $global:EasyAuthBody = ''

  $autopilotToolingManifestPath = Join-Path $repositoryRoot 'agents/autopilot-agent/simple-autopilot-agent/ToolingManifest.json'
  $autopilotToolingManifest = Get-Content -LiteralPath $autopilotToolingManifestPath -Raw | ConvertFrom-Json
  $autopilotConfig = Get-Content -LiteralPath (Join-Path $repositoryRoot 'agents/autopilot-agent/autopilot.json') -Raw | ConvertFrom-Json
  $manifestScopes = @($autopilotToolingManifest.mcpServers.scope | Sort-Object -Unique)
  $publishedScopes = @($autopilotConfig.optionalPermissionScopes.scopes | Sort-Object -Unique)
  Assert-True (
    $manifestScopes.Count -gt 0 -and
    ($manifestScopes -join ',') -eq ($publishedScopes -join ',')
  ) 'Autopilot ToolingManifest scopes do not match the published permission scopes.'

  function global:az {
    $command = $args -join ' '
    $global:AzCalls.Add($command)
    $global:LASTEXITCODE = 0

    if ($command -match 'account get-access-token') {
      return 'fixture-token'
    }
    if ($command -match 'account show.*--query tenantId') {
      return '00000000-0000-0000-0000-000000000001'
    }
    if ($command -match 'account show.*--query id') {
      return '00000000-0000-0000-0000-000000000002'
    }
    if ($command -match 'acr show') {
      return 'fixture.azurecr.io'
    }
    if ($command -match 'webapp config appsettings list') {
      return '[{"name":"ReverseProxy__Routes__old__Match__Path","value":"/old"}]'
    }
    if ($command -match 'rest --method get .*authsettingsV2') {
      return '{"properties":{"globalValidation":{"requireAuthentication":true},"identityProviders":{"azureActiveDirectory":{"enabled":true,"validation":{"allowedAudiences":["api://fixture"],"defaultAuthorizationPolicy":{"allowedPrincipals":{}}}}}}}'
    }
    if ($command -match 'rest --method put .*authsettingsV2') {
      $bodyArgument = @($args | Where-Object { $_ -like '@*' })[0]
      if ($bodyArgument) {
        $global:EasyAuthBody = Get-Content -LiteralPath $bodyArgument.Substring(1) -Raw
      }
    }
  }

  function global:docker {
    $global:LASTEXITCODE = 0
    if (($args -join ' ') -match 'buildx inspect') {
      return 'fixture-builder'
    }
  }

  function global:yq {
    # The agent definition is authored in YAML and read with `yq -r '.name'` by publish-teams.ps1.
    # Emulate that here so the smoke test does not depend on a yq binary being installed.
    $global:LASTEXITCODE = 0
    $manifestPath = @($args | Where-Object { $_ -like '*.yaml' -or $_ -like '*.yml' })[0]
    if ($manifestPath -and (Test-Path -LiteralPath $manifestPath)) {
      foreach ($line in (Get-Content -LiteralPath $manifestPath)) {
        if ($line -match '^\s*name\s*:\s*(.+?)\s*$') {
          return ($Matches[1].Trim('"', "'"))
        }
      }
    }
    return ''
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

    if ($Uri -match '/agents/fixture-agent\?' -and $global:McpPolicyScenario -eq 'resolved') {
      return @{
        name              = 'fixture-agent'
        instance_identity = @{ client_id = '00000000-0000-0000-0000-000000000003' }
      }
    }
    if ($Uri -match '/agents/fixture-agent\?') {
      if ($Method -eq 'Get' -and $global:PromptScenario -eq 'create') {
        throw (New-NotFoundException)
      }
      if ($Method -eq 'Get') {
        return @{
          name     = 'fixture-agent'
          versions = @{
            latest = @{
              blueprint = @{ client_id = '00000000-0000-0000-0000-000000000004' }
            }
          }
        }
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
    if ($Uri -match '/agents\?' -and $Method -eq 'Get' -and $global:McpPolicyScenario -eq 'resolved') {
      return @{ data = @(@{ name = 'fixture-agent' }); has_more = $false }
    }
    if ($Uri -match '/agents\?' -and $Method -eq 'Get') {
      return @{ data = @(); has_more = $false }
    }
    if ($Uri -match '/microsoft365/publish\?' -and $Method -eq 'Post') {
      return @{ titleId = 'fixture-title' }
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
    name                = 'fixture-agent'
    metadata            = @{ enableVnextExperience = 'true' }
    digital_worker_type = 'm365'
    agent_endpoint      = @{
      protocol_configuration = @{
        activity = @{ enable_m365_public_endpoint = $true }
      }
      authorization_schemes = @(@{ type = 'BotServiceRbac' })
    }
    definition          = @{
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
    $global:UploadedMetadata -match '"digital_worker_type": "m365"'
  ) 'Code deploy omitted the M365 digital-worker type.'
  Assert-True (
    $global:UploadedMetadata -match '"enable_m365_public_endpoint": true'
  ) 'Code deploy omitted the M365 public activity endpoint.'
  Assert-True (
    $global:CurlCalls[0] -match 'DigitalWorker=V1Preview'
  ) 'Code deploy omitted the digital-worker feature header.'
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
  'name: fixture-agent' |
    Set-Content -LiteralPath (Join-Path $teamsDirectory 'agent.yaml')
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

  $autopilotDirectory = Join-Path $tempRoot 'autopilot'
  New-Item -ItemType Directory -Path $autopilotDirectory | Out-Null
  'name: fixture-agent' |
    Set-Content -LiteralPath (Join-Path $autopilotDirectory 'agent.yaml')
  @{
    displayName              = 'Fixture Autopilot'
    publishScope             = 'Tenant'
    appVersion               = '1.0.0'
    canRespondWithoutMention = $true
    optionalPermissionScopes = @(
      @{
        resourceAppId = '00000000-0000-0000-0000-000000000002'
        scopes        = @('Fixture.Scope')
      }
    )
  } | ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath (Join-Path $autopilotDirectory 'autopilot.json')

  $global:RestCalls.Clear()
  & "$repositoryRoot/scripts/publish-autopilot.ps1" `
    -AgentDirectory $autopilotDirectory `
    -FoundryProjectEndpoint 'https://fixture.services.ai.azure.com/api/projects/project' `
    -PublishAccessToken 'fixture-publish-token'

  $autopilotCall = @($global:RestCalls | Where-Object {
      $_.Method -eq 'Post' -and $_.Uri -match '/microsoft365/publish\?'
    })
  $autopilotRead = @($global:RestCalls | Where-Object {
      $_.Method -eq 'Get' -and $_.Uri -match '/agents/fixture-agent\?'
    })
  Assert-True ($autopilotRead.Count -eq 1) 'Autopilot publishing did not read the live agent.'
  Assert-True (
    $autopilotRead[0].Headers.Authorization -eq 'Bearer fixture-token'
  ) 'Autopilot agent lookup did not use the managed-identity token.'
  Assert-True ($autopilotCall.Count -eq 1) 'Autopilot publishing did not issue exactly one request.'
  Assert-True (
    $autopilotCall[0].Headers.Authorization -eq 'Bearer fixture-publish-token'
  ) 'Autopilot publishing did not use the delegated user token.'
  Assert-True (
    $autopilotCall[0].Body -match '"publishAsAutopilot": true'
  ) 'Autopilot publishing did not set publishAsAutopilot.'
  Assert-True (
    $autopilotCall[0].Body -notmatch 'botServiceArmId'
  ) 'Autopilot publishing included a Bot Service ARM ID.'
  Assert-True (
    $autopilotCall[0].Body -match '"optionalPermissionScopes"'
  ) 'Autopilot publishing omitted optional permission scopes.'
  Assert-True (
    $autopilotCall[0].Body -match '"useAgenticUserTemplate": true'
  ) 'Autopilot publishing did not enable the agentic-user template.'
  Assert-True (
    $autopilotCall[0].Body -match '"AgentIdentityBlueprintId": "00000000-0000-0000-0000-000000000004"'
  ) 'Autopilot publishing omitted the live blueprint client ID.'
  Assert-True (
    $autopilotCall[0].Body -match '"CommunicationProtocol": "activityProtocol"'
  ) 'Autopilot publishing omitted the activity communication protocol.'
  Write-Host 'PASS Autopilot publish contract without Bot Service'

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
      -McpWebAppName 'fixture-mcp-app' `
      -McpAudience 'api://fixture'
  }
  finally {
    Pop-Location
  }

  Assert-True (
    @($global:AzCalls | Where-Object { $_ -match 'apim-mcp-compliance-all\.bicep' }).Count -eq 1
  ) 'Empty MCP policy did not deploy the deny-all policy.'
  Assert-True (
    $global:EasyAuthBody -match '"allowedPrincipals"\s*:\s*\{\s*\}'
  ) 'Empty MCP policy did not keep Easy Auth deny-all.'
  Write-Host 'PASS empty MCP policy applies APIM and Easy Auth deny-all'

  $resolvedPolicyRoot = Join-Path $tempRoot 'resolved-policy'
  New-Item -ItemType Directory -Path (Join-Path $resolvedPolicyRoot 'mcp') -Force | Out-Null
  @{
    renewalPeriodSeconds = 60
    servers = @(
      @{
        name = 'mcp'
        agents = @(
          @{ name = 'fixture-agent'; requestsPerMinute = 10 }
        )
      }
    )
  } |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath (Join-Path $resolvedPolicyRoot 'mcp/mcp-policy.json')

  $global:McpPolicyScenario = 'resolved'
  $global:EasyAuthBody = ''
  $global:RestCalls.Clear()
  $global:AzCalls.Clear()
  Push-Location $resolvedPolicyRoot
  try {
    & "$repositoryRoot/scripts/apply-mcp-policy.ps1" `
      -FoundryProjectEndpoint 'https://fixture.services.ai.azure.com/api/projects/project' `
      -ResourceGroup 'fixture-rg' `
      -ApimName 'fixture-apim' `
      -McpWebAppName 'fixture-mcp-app' `
      -McpAudience 'api://fixture'
  }
  finally {
    Pop-Location
  }

  $easyAuth = $global:EasyAuthBody | ConvertFrom-Json
  $authorizationPolicy = $easyAuth.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy
  Assert-True (
    @($authorizationPolicy.allowedApplications).Count -eq 1 -and
    $authorizationPolicy.allowedApplications[0] -eq '00000000-0000-0000-0000-000000000003'
  ) 'Resolved MCP policy did not apply the agent application to Easy Auth.'
  Assert-True (
    $authorizationPolicy.PSObject.Properties.Name -notcontains 'allowedPrincipals'
  ) 'Resolved MCP policy retained the deny-all Easy Auth principal requirement.'
  Write-Host 'PASS resolved MCP policy applies APIM and Easy Auth agent allowlists'
  $global:McpPolicyScenario = 'empty'

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
