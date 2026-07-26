<#
.SYNOPSIS
  Bootstraps a self-hosted GitHub Actions runner on the locked-down dev VM.

.DESCRIPTION
  Runs ON the VM via a CustomScriptExtension at provision time (NOT via
  az vm run-command, and it does NOT call the Foundry API — it is provisioning
  glue, so it lives under infra/ next to the vm.bicep module that embeds it).

  Flow (Posture A — persistent, non-ephemeral runner; the VM is trusted because
  only gated, trusted workflows ever run on it):
    1. Acquire a managed-identity token for Key Vault via IMDS (169.254.169.254).
    2. Read the fine-grained PAT from Key Vault over the private data plane.
    3. Mint a short-lived GitHub Actions registration token with that PAT.
    4. Download + configure the runner and install it as a Windows service.

  Idempotent: if the runner service is already installed it exits early, so the
  extension can re-run on subsequent `azd provision` without re-registering.

  Secrets: the PAT is only ever read from Key Vault in-memory on the VM. It is
  never written to disk, the azd env, or the repo. The GitHub registration token
  is short-lived (~1h) and single-use.

.NOTES
  Windows Server has no az CLI preinstalled, so this uses IMDS + REST directly,
  mirroring scripts/seed-agents.ps1.
#>
[CmdletBinding()]
param(
  # e.g. https://github.com/owner/repo
  [Parameter(Mandatory = $true)] [string] $RepoUrl,
  # Key Vault (DNS) name, e.g. aiservicesxxxxkv
  [Parameter(Mandatory = $true)] [string] $KeyVaultName,
  # Name of the KV secret holding the fine-grained PAT (Administration: r/w)
  [Parameter(Mandatory = $true)] [string] $PatSecretName,
  # Comma-separated runner labels
  [Parameter(Mandatory = $false)] [string] $RunnerLabels = 'vnet,foundry-private',
  # Runner version to install (actions/runner release, no leading 'v')
  [Parameter(Mandatory = $false)] [string] $RunnerVersion = '2.328.0',
  # Git for Windows version to install (git-for-windows release, no leading 'v')
  [Parameter(Mandatory = $false)] [string] $GitVersion = '2.47.1',
  [Parameter(Mandatory = $false)] [string] $InstallDir = 'C:\actions-runner'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# The managed Run Command passes -RunnerLabels as `-RunnerLabels vnet,foundry-private`;
# PowerShell argument parsing can split that comma-separated value into an array. Flatten
# and re-join on comma so config.cmd --labels always gets the intended comma-separated list.
$RunnerLabels = ((@($RunnerLabels) -join ' ') -split '[,\s]+' | Where-Object { $_ }) -join ','

# Set when we change the machine PATH after the runner service already exists, so we
# can restart it below to pick up the new PATH (a running service caches its env block).
$script:RunnerNeedsRestart = $false

function Write-Log([string] $Message) {
  Write-Host "[bootstrap-runner] $((Get-Date).ToString('s')) $Message"
}

# --- 0a. Ensure the Azure CLI is installed (admin/SYSTEM context) -------------
# The runner service runs as a NON-admin account (NETWORK SERVICE) and cannot run
# an MSI install from within a workflow step, so install az here where the
# CustomScriptExtension runs as SYSTEM. This lets gated workflows do control-plane
# work on the VM (e.g. create the Azure Bot Service for the Teams / M365 publish
# flow) as the VM managed identity. Runs on every extension execution but is
# idempotent (skips if az is already present). Placed BEFORE the runner
# idempotency check so it also lands on VMs where the runner is already installed.
function Install-AzureCli {
  $azCmd = Join-Path $env:ProgramFiles 'Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
  if ((Get-Command az -ErrorAction SilentlyContinue) -or (Test-Path $azCmd)) {
    Write-Log 'Azure CLI already installed - skipping.'
    return
  }
  Write-Log 'Installing Azure CLI (MSI)...'
  $msi = Join-Path $env:TEMP 'azure-cli.msi'
  Invoke-WebRequest -Uri 'https://aka.ms/installazurecliwindowsx64' -OutFile $msi -UseBasicParsing
  $p = Start-Process 'msiexec.exe' -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart' -Wait -PassThru
  Remove-Item $msi -Force -ErrorAction SilentlyContinue
  if ($p.ExitCode -ne 0) { throw "Azure CLI MSI install failed with exit code $($p.ExitCode)." }
  Write-Log 'Azure CLI installed.'
}
Install-AzureCli

# --- 0b. Ensure Git for Windows is installed (admin/SYSTEM context) -----------
# The microsoft/ai-agent-evals action (nightly eval workflow) runs its steps with
# `shell: bash`, which on Windows resolves to Git Bash (bash.exe). Windows Server ships
# no Git, so install Git for Windows. The default Git install only puts `Git\cmd` (git.exe)
# on PATH — NOT `Git\bin` (bash.exe) — so the runner's `where bash` lookup fails with
# "bash: command not found". Ensure-GitBashOnPath adds `Git\bin` to the machine PATH.
# Both run as SYSTEM (a workflow step running as NETWORK SERVICE could not) and are
# idempotent, and are placed BEFORE the runner idempotency check so they also land on
# VMs where the runner is already installed. (actions/checkout still uses its API-tarball
# fallback and does not require git; this is purely to provide bash for the action.)
function Install-GitForWindows {
  $gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
  if ((Get-Command git -ErrorAction SilentlyContinue) -or (Test-Path $gitBash)) {
    Write-Log 'Git for Windows already installed - skipping install.'
    return
  }
  Write-Log "Installing Git for Windows $GitVersion..."
  $installer = Join-Path $env:TEMP "Git-$GitVersion-64-bit.exe"
  $url = "https://github.com/git-for-windows/git/releases/download/v$GitVersion.windows.1/Git-$GitVersion-64-bit.exe"
  Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
  $p = Start-Process $installer -ArgumentList '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/CLOSEAPPLICATIONS', '/NORESTARTAPPLICATIONS' -Wait -PassThru
  Remove-Item $installer -Force -ErrorAction SilentlyContinue
  if ($p.ExitCode -ne 0) { throw "Git for Windows install failed with exit code $($p.ExitCode)." }
  Write-Log 'Git for Windows installed.'
}
function Ensure-GitBashOnPath {
  $gitBin = Join-Path $env:ProgramFiles 'Git\bin'
  if (-not (Test-Path (Join-Path $gitBin 'bash.exe'))) {
    Write-Log "bash.exe not found under '$gitBin' - skipping PATH update."
    return
  }
  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $parts = @($machinePath -split ';' | Where-Object { $_ })
  if ($parts -contains $gitBin) {
    Write-Log "'$gitBin' already on the machine PATH."
    return
  }
  Write-Log "Adding '$gitBin' to the machine PATH (needed for shell: bash)..."
  [Environment]::SetEnvironmentVariable('Path', ($machinePath.TrimEnd(';') + ';' + $gitBin), 'Machine')
  if (($env:Path -split ';') -notcontains $gitBin) { $env:Path = $env:Path.TrimEnd(';') + ';' + $gitBin }
  $script:RunnerNeedsRestart = $true
}
Install-GitForWindows
Ensure-GitBashOnPath

# --- 0c. Install Python system-wide (admin/SYSTEM context) --------------------
# The nightly eval workflow uses actions/setup-python. The runner service is NON-admin
# (NETWORK SERVICE), so actions/setup-python's install (InstallAllUsers=1) fails when
# run from a workflow step. Install Python system-wide here as SYSTEM using the official
# MSI installer — actions/setup-python then finds it on PATH and skips the install.
# Idempotent, and placed before the runner idempotency check so it also lands on VMs
# where the runner is already installed.
function Install-Python {
  param([string]$Version = '3.10.11')
  if (Get-Command python -ErrorAction SilentlyContinue) {
    $current = (python --version 2>&1) -replace 'Python '
    $majorMinor = "$($Version.Split('.')[0]).$($Version.Split('.')[1])"
    if ($current -like "$majorMinor*") {
      Write-Log "Python $current already installed - skipping."
      return
    }
  }
  Write-Log "Installing Python $Version (system-wide)..."
  $installer = Join-Path $env:TEMP "python-$Version-amd64.exe"
  $url = "https://www.python.org/ftp/python/$Version/python-$Version-amd64.exe"
  Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
  $p = Start-Process $installer -ArgumentList '/quiet', 'InstallAllUsers=1', 'PrependPath=1', 'Include_pip=1' -Wait -PassThru
  Remove-Item $installer -Force -ErrorAction SilentlyContinue
  if ($p.ExitCode -ne 0) { throw "Python installer failed with exit code $($p.ExitCode)." }
  Write-Log "Python $Version installed system-wide."
}
Install-Python

# --- 0d. Idempotency: skip if a runner service already exists ----------------
$existingService = Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue
if ($existingService) {
  if ($script:RunnerNeedsRestart) {
    Write-Log "Restarting runner service '$($existingService.Name)' to pick up the updated PATH..."
    Restart-Service -Name $existingService.Name -Force
  }
  Write-Log "Runner service '$($existingService.Name)' already installed. Nothing to do."
  return
}

# --- 1. Managed-identity token for Key Vault (IMDS) --------------------------
function Get-ImdsToken([string] $Resource) {
  $uri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$([uri]::EscapeDataString($Resource))"
  $resp = Invoke-RestMethod -Uri $uri -Headers @{ Metadata = 'true' } -Method Get
  return $resp.access_token
}

Write-Log 'Acquiring managed-identity token for Key Vault...'
$kvToken = Get-ImdsToken 'https://vault.azure.net'

# --- 2. Read the PAT from Key Vault (private data plane) ----------------------
Write-Log "Reading PAT secret '$PatSecretName' from Key Vault '$KeyVaultName'..."
$secretUri = "https://$KeyVaultName.vault.azure.net/secrets/${PatSecretName}?api-version=7.4"
$pat = (Invoke-RestMethod -Uri $secretUri -Headers @{ Authorization = "Bearer $kvToken" } -Method Get).value
if ([string]::IsNullOrWhiteSpace($pat)) {
  throw "Key Vault secret '$PatSecretName' was empty. Seed it with: az keyvault secret set --vault-name $KeyVaultName --name $PatSecretName --value <PAT>"
}

# --- 3. Mint a GitHub Actions registration token ------------------------------
# Derive owner/repo from the repo URL and call the repo-scoped runner endpoint.
$path = ([uri]$RepoUrl).AbsolutePath.Trim('/')   # "owner/repo"
$ghHeaders = @{
  Authorization          = "Bearer $pat"
  Accept                 = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent'           = 'locked-down-foundry-runner-bootstrap'
}
Write-Log "Requesting runner registration token for '$path'..."
$regToken = (Invoke-RestMethod -Uri "https://api.github.com/repos/$path/actions/runners/registration-token" `
    -Headers $ghHeaders -Method Post).token

# --- 4. Download + configure + install as a service ---------------------------
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Set-Location $InstallDir

$zip = Join-Path $InstallDir "actions-runner-win-x64-$RunnerVersion.zip"
if (-not (Test-Path $zip)) {
  $url = "https://github.com/actions/runner/releases/download/v$RunnerVersion/actions-runner-win-x64-$RunnerVersion.zip"
  Write-Log "Downloading runner $RunnerVersion..."
  Invoke-WebRequest -Uri $url -OutFile $zip
}
Write-Log 'Extracting runner...'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $InstallDir)

$runnerName = "$env:COMPUTERNAME-vnet"
Write-Log "Configuring runner '$runnerName' as a Windows service..."
# --runasservice installs + starts the service; --replace makes re-runs safe.
& "$InstallDir\config.cmd" --unattended --url $RepoUrl --token $regToken `
  --name $runnerName --labels $RunnerLabels --runasservice --replace --work '_work'
if ($LASTEXITCODE -ne 0) { throw "config.cmd failed with exit code $LASTEXITCODE" }

Write-Log 'Runner installed and started as a service.'
