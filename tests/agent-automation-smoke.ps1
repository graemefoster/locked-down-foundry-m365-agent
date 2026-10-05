$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "agent-automation-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$originalGithubOutput = $env:GITHUB_OUTPUT

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
  $env:GITHUB_OUTPUT = Join-Path $tempRoot 'github-output'
  $workflows = @{}
  foreach ($file in Get-ChildItem "$repositoryRoot/.github/workflows/*.yml") {
    $workflow = yq -o=json '.' $file.FullName | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Could not parse workflow '$($file.Name)'." }
    $workflows[$file.Name] = $workflow
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if ($workflow.on.PSObject.Properties.Name -contains 'workflow_call') {
      Assert-True ($workflow.name.StartsWith('Internal: ')) "Reusable workflow '$($file.Name)' is not labelled internal."
      Assert-True ($workflow.on.PSObject.Properties.Name -notcontains 'workflow_dispatch') "Reusable workflow '$($file.Name)' exposes an operator entry point."
    }
    if ($file.Name -ne 'publish-teams.yml') {
      Assert-True ($text -notmatch '--use-device-code|PUBLISH_USER_TOKEN') "Delegated user authentication escaped publishing into '$($file.Name)'."
    }
    Assert-True ($text -notmatch 'az role assignment') "RBAC logic is embedded in '$($file.Name)' instead of a script."
    foreach ($job in $workflow.jobs.PSObject.Properties.Value) {
      foreach ($step in $job.steps) {
        if ($step.shell -ne 'pwsh' -or -not $step.run) { continue }
        $scriptText = $step.run -replace '\$\{\{[\s\S]*?\}\}', 'fixture'
        $tokens = $null; $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$tokens, [ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) "Invalid PowerShell in '$($file.Name)' step '$($step.name)': $parseErrors"
      }
    }
  }
  foreach ($agentName in @('grf-2026-teams-agent', 'grf-2026-autopilot-agent', 'advanced-autopilot-agent', 'support-case-agent', 'support-case-agent-ghcpsdk')) {
    $workflow = $workflows["deploy-$agentName.yml"]
    $publishes = $agentName -notlike 'support-case-*'
    $expectedJobs = if ($publishes) { 'deploy,governance,publish' } else { 'deploy,governance' }
    Assert-True (($workflow.jobs.PSObject.Properties.Name -join ',') -eq $expectedJobs) "Unexpected job graph for '$agentName'."
    Assert-True ($workflow.concurrency.group -eq 'agent-lifecycle' -and $workflow.concurrency.'cancel-in-progress' -eq $false) "Agent '$agentName' must serialize its lifecycle."
    Assert-True ($workflow.jobs.governance.needs -eq 'deploy' -and $workflow.jobs.governance.uses -eq './.github/workflows/deploy-agent-network.yml') "Agent '$agentName' bypasses shared governance."
    if ($publishes) {
      Assert-True ($workflow.jobs.publish.needs -eq 'governance' -and $workflow.jobs.publish.uses -eq './.github/workflows/publish-teams.yml') "Agent '$agentName' bypasses shared publishing."
    }
    if ($agentName -like '*autopilot*') {
      Assert-True ($workflow.jobs.deploy.uses -eq './.github/workflows/_deploy-code-agent.yml' -and $workflow.jobs.deploy.with.'grant-agent-project-access' -eq $true) "Autopilot '$agentName' must opt into script-owned RBAC."
    }
  }
  $governanceSteps = @($workflows['deploy-agent-network.yml'].jobs.apply.steps |
      Where-Object { $_.run -match './scripts/apply-' } |
      ForEach-Object { [regex]::Match($_.run, 'apply-[a-z-]+\.ps1').Value })
  Assert-True (($governanceSteps -join ',') -eq 'apply-token-limits.ps1,apply-yarp-routes.ps1,apply-mcp-policy.ps1,apply-teams-audiences.ps1') 'Governance steps must remain explicit and ordered.'
  Assert-True (
    $workflows['publish-teams.yml'].jobs.publish.steps[-1].run -match './scripts/publish-agent.ps1'
  ) 'Shared publishing must use the Teams/Autopilot dispatcher.'
  $evalConfigScript = @($workflows['nightly-eval-agent.yml'].jobs.evaluate.steps | Where-Object id -eq 'config')[0].run
  Assert-True ($evalConfigScript.Contains("inputs.dataPath || 'agents/grf-2026-teams-agent/eval-data.json'")) 'Scheduled evaluation must supply its data-path default.'
  Write-Host 'PASS lifecycle graphs, identity boundaries, internal workflows, and PowerShell parsing'

  $global:LASTEXITCODE = 0
  $global:AzCalls = [System.Collections.Generic.List[string]]::new()
  $global:CurlCalls = [System.Collections.Generic.List[string]]::new()
  $global:RestCalls = [System.Collections.Generic.List[object]]::new()
  $global:UploadedMetadata = ''
  $global:UploadedZipEntries = @()
  $global:PromptScenario = 'create'
  $global:VersionResponse = @{ version = '2' }
  $global:McpPolicyScenario = 'empty'
  $global:EasyAuthBody = ''
  $global:CodeUploadResponse = @{ version = '3' }
  $global:CodePollResponses = @(@{
    status = 'active'
    instance_identity = @{
      client_id = '00000000-0000-0000-0000-000000000005'
      principal_id = '00000000-0000-0000-0000-000000000006'
    }
  })
  $global:CodePollIndex = 0
  $global:RoleAssignmentScenario = 'success'
  $global:DeploymentEvents = [System.Collections.Generic.List[string]]::new()
  $global:SleepCalls = 0

  function global:Start-Sleep {
    param([int]$Seconds)
    Assert-True ($Seconds -eq 10) 'Unexpected provisioning poll interval.'
    $global:SleepCalls++
  }

  function global:az {
    $command = $args -join ' '
    $global:AzCalls.Add($command)
    $global:LASTEXITCODE = 0

    if ($command -match 'account get-access-token') {
      return 'fixture-token'
    }
    if ($command -match '^role assignment create ') {
      $global:DeploymentEvents.Add('grant')
      if ($global:RoleAssignmentScenario -eq 'exists') {
        $global:LASTEXITCODE = 1
        return 'ERROR: (RoleAssignmentExists) The role assignment already exists.'
      }
      if ($global:RoleAssignmentScenario -eq 'denied') {
        $global:LASTEXITCODE = 1
        return 'ERROR: (AuthorizationFailed) Permission denied.'
      }
      return ''
    }
    if ($command -match 'account show.*--query tenantId') {
      return '00000000-0000-0000-0000-000000000001'
    }
    if ($command -match 'account show.*--query id') {
      return '00000000-0000-0000-0000-000000000002'
    }
    if ($command -match 'ad signed-in-user show') {
      return 'fixture@example.com'
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
    $global:LASTEXITCODE = 0
    $manifestPath = @($args | Where-Object { $_ -like '*.yaml' -or $_ -like '*.yml' })[0]
    if ($args -contains '-o=json') {
      return Get-Content -LiteralPath $manifestPath -Raw
    }

    # Publishing scripts only need the top-level name from the YAML manifest.
    if ($manifestPath -and (Test-Path -LiteralPath $manifestPath)) {
      foreach ($line in (Get-Content -LiteralPath $manifestPath)) {
        if ($line -match '^\s*name\s*:\s*(.+?)\s*$') {
          return ($Matches[1].Trim('"', "'"))
        }
      }
    }
    return ''
  }

  function global:dotnet {
    $global:LASTEXITCODE = 0
    $outputIndex = [Array]::IndexOf($args, '-o')
    if ($outputIndex -ge 0) {
      $outputPath = $args[$outputIndex + 1]
      New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
      [System.IO.File]::WriteAllText((Join-Path $outputPath 'fixture-dotnet.dll'), 'fixture')
    }
  }

  function global:curl {
    $global:DeploymentEvents.Add('upload')
    $global:CurlCalls.Add(($args -join ' '))
    $metadataArgument = @($args | Where-Object { $_ -like 'metadata=@*' })[0]
    if ($metadataArgument) {
      $metadataPath = ($metadataArgument -replace '^metadata=@', '') -replace ';type=application/json$', ''
      $global:UploadedMetadata = Get-Content -LiteralPath $metadataPath -Raw
    }
    $codeArgument = @($args | Where-Object { $_ -like 'code=@*' })[0]
    if ($codeArgument) {
      $codePath = ($codeArgument -replace '^code=@', '') -replace ';type=application/zip$', ''
      $archive = [System.IO.Compression.ZipFile]::OpenRead($codePath)
      try {
        $global:UploadedZipEntries = @($archive.Entries | ForEach-Object FullName)
      }
      finally {
        $archive.Dispose()
      }
    }
    $global:LASTEXITCODE = 0
    return $global:CodeUploadResponse | ConvertTo-Json -Depth 10
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

    if ($Method -eq 'Patch') {
      $global:DeploymentEvents.Add('patch')
    }
    if ($Uri -match '/versions/3\?' -and $Method -eq 'Get') {
      $global:DeploymentEvents.Add('poll')
      $index = [Math]::Min($global:CodePollIndex, $global:CodePollResponses.Count - 1)
      $global:CodePollIndex++
      $pollResponse = $global:CodePollResponses[$index]
      if ($pollResponse -is [System.Exception]) { throw $pollResponse }
      return $pollResponse
    }
    if ($Uri -match '/agents/fixture-agent\?' -and $global:McpPolicyScenario -eq 'resolved') {
      return @{
        name              = 'fixture-agent'
        instance_identity = @{ client_id = '00000000-0000-0000-0000-000000000003' }
      }
    }
    if ($Uri -match '/agents/fixture-agent\?' -and $global:PromptScenario -eq 'autopilot') {
      return @{
        name      = 'fixture-agent'
        blueprint = @{ client_id = '00000000-0000-0000-0000-000000000004' }
      }
    }
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

  $scheduledConfigScript = $evalConfigScript.Replace(
    '${{ inputs.dataPath || ''agents/grf-2026-teams-agent/eval-data.json'' }}',
    'agents/grf-2026-teams-agent/eval-data.json'
  ).Replace('${{ vars.AZURE_AI_PROJECT_ENDPOINT }}', 'https://fixture.services.ai.azure.com/api/projects/project'
  ).Replace('${{ vars.AZURE_AI_MODEL_DEPLOYMENT_NAME }}', 'fixture-model'
  ) -replace '\$\{\{ inputs\.[a-zA-Z]+ \}\}', ''
  Push-Location $repositoryRoot
  try {
    & ([scriptblock]::Create($scheduledConfigScript))
  }
  finally {
    Pop-Location
  }
  $evaluationOutputs = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw
  Assert-True ($evaluationOutputs -match 'agent-ids=grf-2026-teams-agent:4') 'Scheduled evaluation must resolve a valid name:version.'
  Assert-True ($evaluationOutputs -match 'data-path=agents/grf-2026-teams-agent/eval-data.json') 'Scheduled evaluation must use the default data file.'
  $global:RestCalls.Clear()
  Clear-Content -LiteralPath $env:GITHUB_OUTPUT
  Write-Host 'PASS scheduled evaluation input resolution'

  $promptAgentPath = Join-Path $tempRoot 'prompt-agent.json'
  $mcpConfigPath = Join-Path $tempRoot 'mcp.json'
  @{
    name       = 'fixture-agent'
    definition = @{
      kind  = 'prompt'
      model = 'fixture-model'
      tools = @(
        @{
          type                  = 'mcp'
          server_label          = 'weather-label'
          project_connection_id = 'weather-connection'
        },
        @{
          type                  = 'mcp'
          server_label          = 'crm'
          project_connection_id = 'crm'
        }
      )
    }
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $promptAgentPath
  @{
    servers = @(
      @{
        name           = 'weather'
        connectionName = 'weather-connection'
      },
      @{
        name = 'crm'
      }
    )
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $mcpConfigPath

  & "$repositoryRoot/scripts/deploy-prompt-agent.ps1" `
    -AgentJsonPath $promptAgentPath `
    -FoundryProjectEndpoint 'https://fixture.services.ai.azure.com/api/projects/project' `
    -McpGatewayUrl 'https://fixture.example/weather/' `
    -McpConfigPath $mcpConfigPath

  $createCall = @($global:RestCalls | Where-Object {
      $_.Method -eq 'Post' -and $_.Uri -match '/agents\?'
    })
  $createPublish = @($global:RestCalls | Where-Object { $_.Method -eq 'Patch' })
  Assert-True ($createCall.Count -eq 1) 'Prompt create did not issue exactly one create request.'
  Assert-True ($createCall[0].Body -match 'https://fixture.example/weather/') 'Prompt create did not map the connection-backed MCP URL.'
  Assert-True ($createCall[0].Body -match 'https://fixture.example/crm/') 'Prompt create did not map the label-backed MCP URL.'
  Assert-True ($createPublish[0].Body -match '"agent_version": "1"') 'Prompt create did not serve version 1.'

  $global:PromptScenario = 'version'
  $global:RestCalls.Clear()

  & "$repositoryRoot/scripts/deploy-prompt-agent.ps1" `
    -AgentJsonPath $promptAgentPath `
    -FoundryProjectEndpoint 'https://fixture.services.ai.azure.com/api/projects/project' `
    -McpGatewayUrl 'https://fixture.example/' `
    -McpConfigPath $mcpConfigPath

  $versionCall = @($global:RestCalls | Where-Object {
      $_.Method -eq 'Post' -and $_.Uri -match '/versions\?'
    })
  $versionPublish = @($global:RestCalls | Where-Object { $_.Method -eq 'Patch' })
  Assert-True ($versionCall.Count -eq 1) 'Prompt update did not issue exactly one version request.'
  Assert-True ($versionPublish[0].Body -match '"agent_version": "2"') 'Prompt update did not serve version 2.'
  Write-Host 'PASS prompt MCP mapping, create, version, and served-version routing'

  $pythonAgentDirectory = Join-Path $tempRoot 'python-wrapper'
  $pythonSourceDirectory = Join-Path $pythonAgentDirectory 'hello_module'
  New-Item -ItemType Directory -Path $pythonSourceDirectory -Force | Out-Null
  '' | Set-Content -LiteralPath (Join-Path $pythonSourceDirectory '__init__.py')
  'print("fixture")' | Set-Content -LiteralPath (Join-Path $pythonSourceDirectory '__main__.py')
  'fixture-package' | Set-Content -LiteralPath (Join-Path $pythonSourceDirectory 'requirements.txt')
  @{
    name       = 'fixture-agent'
    definition = @{
      kind = 'hosted'
      code_configuration = @{
        runtime     = 'python_3_13'
        entry_point = @('python', '-m', 'hello_module')
      }
      environment_variables = @{}
    }
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $pythonAgentDirectory 'agent.yaml')

  $global:PromptScenario = 'version'
  $global:CurlCalls.Clear()
  $global:RestCalls.Clear()
  & "$repositoryRoot/scripts/deploy-agent.ps1" `
    -AgentDirectory $pythonAgentDirectory `
    -SourceDirectory hello_module `
    -FoundryProjectEndpoint 'https://fixture.services.ai.azure.com/api/projects/project'
  Assert-True ($global:CurlCalls.Count -eq 1) 'The wrapper did not package and deploy the Python agent.'
  Assert-True (
    $global:UploadedZipEntries -contains 'hello_module/__main__.py'
  ) 'The wrapper flattened a Python module instead of preserving its package directory.'
  Assert-True (
    $global:UploadedZipEntries -contains 'requirements.txt'
  ) 'The wrapper did not place Python dependency metadata at the ZIP root.'

  $dotnetAgentDirectory = Join-Path $tempRoot 'dotnet-wrapper'
  $dotnetSourceDirectory = Join-Path $dotnetAgentDirectory 'src'
  New-Item -ItemType Directory -Path $dotnetSourceDirectory -Force | Out-Null
  '<Project Sdk="Microsoft.NET.Sdk"></Project>' |
    Set-Content -LiteralPath (Join-Path $dotnetSourceDirectory 'fixture.csproj')
  @{
    name       = 'fixture-agent'
    definition = @{
      kind = 'hosted'
      code_configuration = @{
        runtime     = 'dotnet_10'
        entry_point = @('dotnet', 'fixture-dotnet.dll')
      }
      environment_variables = @{}
    }
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dotnetAgentDirectory 'agent.yaml')

  $global:CurlCalls.Clear()
  $global:RestCalls.Clear()
  & "$repositoryRoot/scripts/deploy-agent.ps1" `
    -AgentDirectory $dotnetAgentDirectory `
    -SourceDirectory src `
    -FoundryProjectEndpoint 'https://fixture.services.ai.azure.com/api/projects/project'
  Assert-True ($global:CurlCalls.Count -eq 1) 'The wrapper did not publish, package, and deploy the .NET agent.'
  Write-Host 'PASS wrapper packages Python and .NET source agents'

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
  $codePackageDirectory = Join-Path $tempRoot 'code-package'
  New-Item -ItemType Directory -Path $codePackageDirectory | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $codePackageDirectory 'fixture.dll'), 'fixture')
  [System.IO.Compression.ZipFile]::CreateFromDirectory($codePackageDirectory, $zipPath)

  $global:PromptScenario = 'version'
  $global:CurlCalls.Clear()
  $global:RestCalls.Clear()
  $global:UploadedMetadata = ''
  $global:AzCalls.Clear()

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
  Assert-True (
    @($global:AzCalls | Where-Object { $_ -match '^role assignment' }).Count -eq 0 -and
    @($global:RestCalls | Where-Object { $_.Uri -match '/versions/3\?' }).Count -eq 0
  ) 'M365 metadata must not trigger role assignment or identity polling without opt-in.'
  Write-Host 'PASS source-zip multipart upload and endpoint injection'

  $projectId = '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/fixture-rg/providers/Microsoft.CognitiveServices/accounts/fixture/projects/project'
  $codeDeployParameters = @{
    AgentJsonPath = $codeAgentPath
    ZipPath = $zipPath
    FoundryProjectEndpoint = 'https://fixture.services.ai.azure.com/api/projects/project'
    FoundryProjectId = $projectId
    GrantAgentProjectAccess = $true
  }
  $activeVersion = @{
    version = '3'
    status = 'active'
    instance_identity = @{
      client_id = '00000000-0000-0000-0000-000000000005'
      principal_id = '00000000-0000-0000-0000-000000000006'
    }
  }
  $global:CodePollResponses = @(@{ status = 'provisioning' }, $activeVersion)
  $global:DeploymentEvents.Clear()
  $global:AzCalls.Clear()
  $global:RestCalls.Clear()

  & "$repositoryRoot/scripts/deploy-agent.ps1" `
    -AgentDirectory $pythonAgentDirectory `
    -SourceDirectory hello_module `
    -FoundryProjectEndpoint $codeDeployParameters.FoundryProjectEndpoint `
    -FoundryProjectId $projectId `
    -GrantAgentProjectAccess

  Assert-True (($global:DeploymentEvents -join ',') -eq 'upload,poll,poll,grant,patch') 'Source wrapper must wait for provisioning, grant access, then switch traffic.'
  $grantCalls = @($global:AzCalls | Where-Object { $_ -match '^role assignment create ' })
  Assert-True ($grantCalls.Count -eq 1) 'Expected exactly one project role grant.'
  Assert-True ($grantCalls[0] -match "--assignee-object-id $($activeVersion.instance_identity.principal_id) --assignee-principal-type ServicePrincipal --role Foundry User --scope $([regex]::Escape($projectId)) --output none") 'Grant must use the instance principal ID and explicit service-principal type without a Graph lookup.'
  Assert-True (@($global:AzCalls | Where-Object { $_ -match '^login|Cognitive Services User' }).Count -eq 0) 'Deployment must not switch identities or grant account-wide access.'
  Assert-True ($global:UploadedMetadata -notmatch 'digital_worker_type') 'Opt-in should also work for a non-M365 source agent.'
  foreach ($call in $global:RestCalls) {
    Assert-True ($call.Headers.Authorization -eq 'Bearer fixture-token') 'Foundry requests must use the acquired AI token.'
  }
  Write-Host 'PASS non-M365 source wrapper grants the instance identity before switching traffic'

  $global:CodeUploadResponse = $activeVersion
  $global:RoleAssignmentScenario = 'exists'
  $global:DeploymentEvents.Clear()
  & "$repositoryRoot/scripts/deploy-agent.ps1" `
    -AgentDirectory $pythonAgentDirectory `
    -SourceDirectory hello_module `
    -FoundryProjectEndpoint $codeDeployParameters.FoundryProjectEndpoint `
    -FoundryProjectId $projectId `
    -GrantAgentProjectAccess
  Assert-True (($global:DeploymentEvents -join ',') -eq 'upload,grant,patch') 'An existing grant must not fail the wrapper due to a stale CLI exit code.'

  $global:RoleAssignmentScenario = 'success'
  $global:CodeUploadResponse = @{ versions = @{ latest = $activeVersion } }
  $global:DeploymentEvents.Clear()
  Clear-Content -LiteralPath $env:GITHUB_OUTPUT
  & "$repositoryRoot/scripts/deploy-code-agent.ps1" @codeDeployParameters
  Assert-True (($global:DeploymentEvents -join ',') -eq 'upload,grant,patch') 'Nested create response must supply the active version and identity without extra discovery.'
  Assert-True (
    ((Get-Content -LiteralPath $env:GITHUB_OUTPUT) -join ',') -eq 'agent-name=fixture-agent,agent-version=3'
  ) 'Successful deployment must emit the served agent name and version.'

  $global:CodeUploadResponse = @{ version = '3'; status = 'active' }
  $global:CodePollResponses = @($activeVersion)
  $global:DeploymentEvents.Clear()
  & "$repositoryRoot/scripts/deploy-code-agent.ps1" @codeDeployParameters
  Assert-True (($global:DeploymentEvents -join ',') -eq 'upload,poll,grant,patch') 'Active versions without an identity must still be polled.'
  Write-Host 'PASS existing grants and create-response identity shapes'

  $failureCases = @(
    @{ Name = 'missing scope'; Scope = ''; Error = 'full Foundry project ARM'; Events = ''; Polls = 0 },
    @{ Name = 'account scope'; Scope = ($projectId -replace '/projects/project$', ''); Error = 'full Foundry project ARM'; Events = ''; Polls = 0 },
    @{ Name = 'data-plane scope'; Scope = $codeDeployParameters.FoundryProjectEndpoint; Error = 'full Foundry project ARM'; Events = ''; Polls = 0 },
    @{ Name = 'failed creation'; Upload = @{ version = '3'; status = 'failed' }; Error = 'provisioning failed'; Events = 'upload'; Polls = 0 },
    @{ Name = 'failed provisioning'; Poll = @{ status = 'failed' }; Error = 'provisioning failed'; Events = 'upload,poll'; Polls = 1 },
    @{ Name = 'provisioning timeout'; Poll = @{ status = 'provisioning' }; Error = "expected 'active'"; Polls = 30 },
    @{ Name = 'missing identity'; Poll = @{ status = 'active' }; Error = 'no instance_identity.principal_id'; Polls = 30 },
    @{ Name = 'client ID is not principal ID'; Poll = @{ status = 'active'; instance_identity = @{ client_id = '00000000-0000-0000-0000-000000000005' } }; Error = 'no instance_identity.principal_id'; Polls = 30 },
    @{ Name = 'poll unauthorized'; Poll = [System.Exception]::new('HTTP 401 from version poll'); Error = 'HTTP 401'; Events = 'upload,poll'; Polls = 1 },
    @{ Name = 'grant denied'; Upload = $activeVersion; Role = 'denied'; Error = 'roleAssignments/write.*AuthorizationFailed'; Events = 'upload,grant'; Polls = 0 }
  )
  foreach ($case in $failureCases) {
    $global:CodeUploadResponse = if ($case.ContainsKey('Upload')) { $case.Upload } else { @{ version = '3' } }
    $global:CodePollResponses = @(if ($case.ContainsKey('Poll')) { $case.Poll } else { $activeVersion })
    $global:CodePollIndex = 0
    $global:SleepCalls = 0
    $global:RoleAssignmentScenario = if ($case.ContainsKey('Role')) { $case.Role } else { 'success' }
    $global:DeploymentEvents.Clear()
    $global:RestCalls.Clear()
    Clear-Content -LiteralPath $env:GITHUB_OUTPUT
    $parameters = $codeDeployParameters.Clone()
    if ($case.ContainsKey('Scope')) { $parameters.FoundryProjectId = $case.Scope }
    $failure = $null
    try {
      & "$repositoryRoot/scripts/deploy-code-agent.ps1" @parameters
    }
    catch {
      $failure = $_
    }
    Assert-True ($null -ne $failure -and $failure.Exception.Message -match $case.Error) "Expected explicit failure for '$($case.Name)', got: $failure"
    Assert-True ($global:CodePollIndex -eq $case.Polls) "Incorrect poll count for '$($case.Name)'."
    Assert-True (-not $global:DeploymentEvents.Contains('patch')) "Failed '$($case.Name)' must not switch traffic."
    Assert-True ([string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw))) "Failed '$($case.Name)' must not emit successful deployment outputs."
    if ($case.ContainsKey('Events')) {
      Assert-True (($global:DeploymentEvents -join ',') -eq $case.Events) "Unexpected operations for '$($case.Name)'."
    }
    if ($case.Polls -eq 30) {
      Assert-True ($global:SleepCalls -eq 29) 'Polling must stop after 30 attempts with ten-second intervals.'
    }
    if ($case.Polls -eq 0 -and $case.ContainsKey('Scope')) {
      Assert-True ($global:RestCalls.Count -eq 0) 'Invalid scope must fail before contacting Foundry.'
    }
  }
  $global:RoleAssignmentScenario = 'success'
  $global:CodeUploadResponse = @{ version = '3' }
  Write-Host 'PASS RBAC preflight, denied grant, provisioning failure, timeout, and missing identity'

  foreach ($kind in @('prompt', 'hosted')) {
    $unsupportedDirectory = Join-Path $tempRoot "rbac-unsupported-$kind"
    New-Item -ItemType Directory -Path $unsupportedDirectory | Out-Null
    @{
      name = 'fixture-agent'
      definition = @{ kind = $kind; image = 'fixture-image' }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $unsupportedDirectory 'agent.yaml')
    $global:DeploymentEvents.Clear()
    $failure = $null
    try {
      & "$repositoryRoot/scripts/deploy-agent.ps1" `
        -AgentDirectory $unsupportedDirectory `
        -FoundryProjectEndpoint $codeDeployParameters.FoundryProjectEndpoint `
        -FoundryProjectId $projectId `
        -GrantAgentProjectAccess
    }
    catch {
      $failure = $_
    }
    Assert-True ($null -ne $failure -and $failure.Exception.Message -match 'supported only for hosted source agents') 'Prompt/image deployments must reject, not silently ignore, source-only RBAC opt-in.'
    Assert-True ($global:DeploymentEvents.Count -eq 0) 'Unsupported RBAC opt-in must not deploy anything.'
  }

  $imageAgentPath = Join-Path $tempRoot 'image-agent.json'
  $buildContext = Join-Path $tempRoot 'image-build'
  New-Item -ItemType Directory -Path $buildContext | Out-Null
  'FROM scratch' | Set-Content -LiteralPath (Join-Path $buildContext 'Dockerfile')
  @{
    name       = 'fixture-agent'
    definition = @{
      kind  = 'hosted'
      image = ''
      environment_variables = @{
        FOUNDRY_PROJECT_ENDPOINT = ''
      }
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
        $_.Method -eq 'Post' -and $_.Body -match 'https://fixture.services.ai.azure.com/api/projects/project'
      }).Count -eq 1
  ) 'Image deploy did not inject FOUNDRY_PROJECT_ENDPOINT.'
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

  $global:PromptScenario = 'autopilot'
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
  & "$repositoryRoot/scripts/publish-agent.ps1" `
    -AgentDirectory $autopilotDirectory `
    -FoundryProjectEndpoint 'https://fixture.services.ai.azure.com/api/projects/project'

  $autopilotCall = @($global:RestCalls | Where-Object {
      $_.Method -eq 'Post' -and $_.Uri -match '/microsoft365/publish\?'
    })
  Assert-True ($autopilotCall.Count -eq 1) 'Autopilot publishing did not issue exactly one request.'
  Assert-True (
    $autopilotCall[0].Body -match '"publishAsAutopilot": true'
  ) 'Autopilot publishing did not set publishAsAutopilot.'
  Assert-True (
    $autopilotCall[0].Body -notmatch 'botServiceArmId'
  ) 'Autopilot publishing included a Bot Service ARM ID.'
  Assert-True (
    $autopilotCall[0].Body -match '"optionalPermissionScopes"'
  ) 'Autopilot publishing omitted optional permission scopes.'
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
  Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
  $env:GITHUB_OUTPUT = $originalGithubOutput
  Remove-Item Env:\GITHUB_SHA -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'All agent automation smoke tests passed.'
