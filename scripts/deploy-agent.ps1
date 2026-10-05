#!/usr/bin/env pwsh

param(
  [Parameter(Mandatory = $true)] [string]$AgentDirectory,
  [Parameter(Mandatory = $false)] [string]$FoundryProjectEndpoint = $env:AZURE_AI_PROJECT_ENDPOINT,
  [Parameter(Mandatory = $false)] [string]$FoundryProjectId = $env:AZURE_AI_PROJECT_ID,
  [switch]$GrantAgentProjectAccess,
  [Parameter(Mandatory = $false)] [string]$SourceDirectory = '',
  [Parameter(Mandatory = $false)] [string]$McpGatewayUrl = $env:MCP_GATEWAY_URL,
  [Parameter(Mandatory = $false)] [string]$McpConfigPath = '',
  [Parameter(Mandatory = $false)] [string]$AcrName = $env:AZURE_CONTAINER_REGISTRY_NAME,
  [Parameter(Mandatory = $false)] [string]$ImageRepository = '',
  [Parameter(Mandatory = $false)] [string]$Dockerfile = 'Dockerfile'
)

$ErrorActionPreference = 'Stop'

function Assert-Command {
  param(
    [Parameter(Mandatory = $true)] [string]$Name,
    [Parameter(Mandatory = $true)] [string]$InstallHint
  )

  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -eq $command) {
    throw "The '$Name' command is required. $InstallHint"
  }
  return $command
}

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$agentDirectoryPath = (Resolve-Path -LiteralPath $AgentDirectory).Path
$manifestPath = Join-Path $agentDirectoryPath 'agent.yaml'

if (-not (Test-Path -LiteralPath $manifestPath)) {
  throw "Agent deployment manifest not found: $manifestPath"
}
if ([string]::IsNullOrWhiteSpace($FoundryProjectEndpoint)) {
  throw 'FoundryProjectEndpoint is required. Pass it explicitly or set AZURE_AI_PROJECT_ENDPOINT.'
}

$yq = Assert-Command -Name yq -InstallHint 'On macOS, run: brew install yq'
$null = Assert-Command -Name az -InstallHint 'Install Azure CLI, then run az login.'

if ([string]::IsNullOrWhiteSpace($McpConfigPath)) {
  $McpConfigPath = Join-Path $repositoryRoot 'mcp/mcp.json'
}
elseif (-not [System.IO.Path]::IsPathRooted($McpConfigPath)) {
  $McpConfigPath = Join-Path $repositoryRoot $McpConfigPath
}

if (-not [string]::IsNullOrWhiteSpace($SourceDirectory)) {
  if (-not [System.IO.Path]::IsPathRooted($SourceDirectory)) {
    $SourceDirectory = Join-Path $agentDirectoryPath $SourceDirectory
  }
  $SourceDirectory = (Resolve-Path -LiteralPath $SourceDirectory).Path
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "agent-deploy-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
  $agentJsonPath = Join-Path $tempRoot 'agent.json'
  & $yq -o=json '.' $manifestPath | Set-Content -LiteralPath $agentJsonPath -Encoding utf8
  if ($LASTEXITCODE -ne 0) {
    throw "Could not normalize '$manifestPath' with yq."
  }

  $agent = Get-Content -LiteralPath $agentJsonPath -Raw | ConvertFrom-Json
  $agentName = [string]$agent.name
  $kind = [string]$agent.definition.kind

  if ([string]::IsNullOrWhiteSpace($agentName)) {
    throw "Agent manifest has no name: $manifestPath"
  }
  if ([string]::IsNullOrWhiteSpace($kind)) {
    throw "Agent '$agentName' has no definition.kind."
  }
  if ($GrantAgentProjectAccess -and ($kind -ne 'hosted' -or $null -eq $agent.definition.code_configuration)) {
    throw 'GrantAgentProjectAccess is supported only for hosted source agents.'
  }

  if ($kind -eq 'prompt') {
    & "$PSScriptRoot/deploy-prompt-agent.ps1" `
      -AgentJsonPath $agentJsonPath `
      -FoundryProjectEndpoint $FoundryProjectEndpoint `
      -McpGatewayUrl $McpGatewayUrl `
      -McpConfigPath $McpConfigPath
    if ($LASTEXITCODE -ne 0) {
      throw "Prompt-agent deployment failed for '$agentName'."
    }
    return
  }

  if ($kind -ne 'hosted') {
    throw "Agent '$agentName' has unsupported definition.kind '$kind'."
  }

  if ($null -ne $agent.definition.code_configuration) {
    $runtime = [string]$agent.definition.code_configuration.runtime
    $entryPoint = @($agent.definition.code_configuration.entry_point)
    $packageRoot = Join-Path $tempRoot 'package'

    if ($runtime.StartsWith('dotnet_', [System.StringComparison]::OrdinalIgnoreCase)) {
      $null = Assert-Command -Name dotnet -InstallHint 'Install the .NET SDK required by the configured runtime.'

      if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
        $projects = @(Get-ChildItem -LiteralPath $agentDirectoryPath -Recurse -File -Filter '*.csproj' |
            Where-Object { $_.FullName -notmatch '[/\\](bin|obj|tests?)[/\\]' })
        if ($projects.Count -ne 1) {
          throw "Found $($projects.Count) .NET projects under '$agentDirectoryPath'. Pass SourceDirectory to select one."
        }
        $SourceDirectory = $projects[0].DirectoryName
        $projectPath = $projects[0].FullName
      }
      else {
        $projects = @(Get-ChildItem -LiteralPath $SourceDirectory -File -Filter '*.csproj')
        if ($projects.Count -ne 1) {
          throw "Found $($projects.Count) .NET projects in '$SourceDirectory'. SourceDirectory must contain exactly one project."
        }
        $projectPath = $projects[0].FullName
      }

      New-Item -ItemType Directory -Path $packageRoot | Out-Null
      dotnet publish $projectPath -c Release -o $packageRoot
      if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed for '$projectPath'."
      }

      $entryDll = [string](@($entryPoint | Where-Object { [string]$_ -match '\.dll$' }) | Select-Object -Last 1)
      if ([string]::IsNullOrWhiteSpace($entryDll) -or -not (Test-Path -LiteralPath (Join-Path $packageRoot $entryDll))) {
        throw "Published output for '$agentName' does not contain its configured entry DLL '$entryDll'."
      }
    }
    elseif ($runtime.StartsWith('python_', [System.StringComparison]::OrdinalIgnoreCase)) {
      $moduleIndex = [Array]::IndexOf($entryPoint, '-m')
      $isModuleEntryPoint = $moduleIndex -ge 0 -and $moduleIndex + 1 -lt $entryPoint.Count
      $entryTarget = [string]($entryPoint | Select-Object -Last 1)
      if ([string]::IsNullOrWhiteSpace($entryTarget)) {
        throw "Python agent '$agentName' has no configured entry point."
      }

      if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
        if ($isModuleEntryPoint) {
          $moduleLeaf = ($entryTarget -split '\.')[-1]
          $moduleDirectories = @(Get-ChildItem -LiteralPath $agentDirectoryPath -Recurse -Directory -Filter $moduleLeaf |
              Where-Object {
                $_.FullName -notmatch '[/\\](\.venv|__pycache__|tests?)[/\\]' -and
                (Test-Path -LiteralPath (Join-Path $_.FullName '__main__.py'))
              })
          if ($moduleDirectories.Count -ne 1) {
            throw "Found $($moduleDirectories.Count) Python packages for module '$entryTarget'. Pass SourceDirectory to select one."
          }
          $SourceDirectory = $moduleDirectories[0].FullName
        }
        else {
          $entryName = Split-Path $entryTarget -Leaf
          $entryFiles = @(Get-ChildItem -LiteralPath $agentDirectoryPath -Recurse -File -Filter $entryName |
              Where-Object { $_.FullName -notmatch '[/\\](\.venv|__pycache__|tests?)[/\\]' })
          if ($entryFiles.Count -ne 1) {
            throw "Found $($entryFiles.Count) '$entryName' files under '$agentDirectoryPath'. Pass SourceDirectory to select one."
          }
          $SourceDirectory = $entryFiles[0].DirectoryName
        }
      }

      if ($isModuleEntryPoint) {
        $modulePath = $entryTarget.Replace('.', [System.IO.Path]::DirectorySeparatorChar)
        $sourceIsPackage = (
          (Split-Path $SourceDirectory -Leaf) -eq (($entryTarget -split '\.')[-1]) -and
          (Test-Path -LiteralPath (Join-Path $SourceDirectory '__main__.py'))
        )

        if ($sourceIsPackage) {
          $packageRoot = Join-Path $tempRoot 'python-package'
          New-Item -ItemType Directory -Path $packageRoot | Out-Null

          $moduleParent = Split-Path (Join-Path $packageRoot $modulePath) -Parent
          New-Item -ItemType Directory -Path $moduleParent -Force | Out-Null
          Copy-Item -LiteralPath $SourceDirectory -Destination $moduleParent -Recurse

          foreach ($dependencyFile in @('requirements.txt', 'pyproject.toml')) {
            $dependencyPath = Join-Path $SourceDirectory $dependencyFile
            if (Test-Path -LiteralPath $dependencyPath) {
              Copy-Item -LiteralPath $dependencyPath -Destination (Join-Path $packageRoot $dependencyFile)
            }
          }
        }
        elseif (Test-Path -LiteralPath (Join-Path $SourceDirectory "$modulePath/__main__.py")) {
          $packageRoot = $SourceDirectory
        }
        else {
          throw "Python source '$SourceDirectory' does not contain module '$entryTarget' with __main__.py."
        }
      }
      elseif (-not (Test-Path -LiteralPath (Join-Path $SourceDirectory $entryTarget))) {
        throw "Python source '$SourceDirectory' does not contain the configured entry point '$entryTarget'."
      }
      else {
        $packageRoot = $SourceDirectory
      }
    }
    else {
      throw "Agent '$agentName' uses unsupported code runtime '$runtime'."
    }

    $zipPath = Join-Path $tempRoot 'agent.zip'
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
      $packageRoot,
      $zipPath,
      [System.IO.Compression.CompressionLevel]::Optimal,
      $false
    )

    & "$PSScriptRoot/deploy-code-agent.ps1" `
      -AgentJsonPath $agentJsonPath `
      -ZipPath $zipPath `
      -FoundryProjectEndpoint $FoundryProjectEndpoint `
      -FoundryProjectId $FoundryProjectId `
      -GrantAgentProjectAccess:$GrantAgentProjectAccess
    return
  }

  if ($agent.definition.PSObject.Properties.Name -contains 'image') {
    $null = Assert-Command -Name docker -InstallHint 'Install and start Docker Desktop or another Docker-compatible engine.'
    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
      throw 'Docker is installed but its engine is not running.'
    }

    if ([string]::IsNullOrWhiteSpace($AcrName)) {
      throw "AcrName is required for image agent '$agentName'. Pass it explicitly or set AZURE_CONTAINER_REGISTRY_NAME."
    }
    if ([string]::IsNullOrWhiteSpace($ImageRepository)) {
      $ImageRepository = $agentName
    }

    if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
      $dockerfiles = @(Get-ChildItem -LiteralPath $agentDirectoryPath -Recurse -File -Filter $Dockerfile)
      if ($dockerfiles.Count -ne 1) {
        throw "Found $($dockerfiles.Count) '$Dockerfile' files under '$agentDirectoryPath'. Pass SourceDirectory to select one."
      }
      $SourceDirectory = $dockerfiles[0].DirectoryName
      $Dockerfile = $dockerfiles[0].Name
    }

    & "$PSScriptRoot/deploy-image-agent.ps1" `
      -AgentJsonPath $agentJsonPath `
      -FoundryProjectEndpoint $FoundryProjectEndpoint `
      -AcrName $AcrName `
      -ImageRepository $ImageRepository `
      -BuildContext $SourceDirectory `
      -Dockerfile $Dockerfile
    if ($LASTEXITCODE -ne 0) {
      throw "Image-agent deployment failed for '$agentName'."
    }
    return
  }

  throw "Hosted agent '$agentName' has neither code_configuration nor image deployment settings."
}
finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
