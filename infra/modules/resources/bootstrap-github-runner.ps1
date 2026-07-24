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
# `shell: bash`, which on Windows resolves to Git Bash. Windows Server ships no
# Git, so install Git for Windows to the default location the runner probes for
# bash.exe (%ProgramFiles%\Git\bin\bash.exe). Like Install-AzureCli this runs as
# SYSTEM (a workflow step running as NETWORK SERVICE could not) and is idempotent,
# and is placed BEFORE the runner idempotency check so it also lands on VMs where
# the runner is already installed. (actions/checkout still uses its API-tarball
# fallback and does not require git; this is purely to provide bash for the action.)
function Install-GitForWindows {
  $gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
  if ((Get-Command git -ErrorAction SilentlyContinue) -or (Test-Path $gitBash)) {
    Write-Log 'Git for Windows already installed - skipping.'
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
Install-GitForWindows

# --- 0c. Pre-seed Python into the runner tool cache (admin/SYSTEM context) -----
# The nightly eval workflow uses actions/setup-python, whose install runs the Python
# installer with InstallAllUsers=1 and creates a machine symlink — both require
# elevation. The runner service is NON-admin (NETWORK SERVICE), so that install fails
# ("Error happened during Python installation"). Pre-seed Python here, as SYSTEM, into
# the runner's tool cache (_work\_tool) using the SAME actions/python-versions package
# setup-python would use; it writes the `x64.complete` marker, so setup-python then
# finds the cached version and skips the elevated install. We reuse python-versions'
# own setup.ps1 (resolved from its manifest) so the exact install steps stay in sync.
# Idempotent, and placed before the runner idempotency check so it also lands on VMs
# where the runner is already installed.
function Install-PythonToolcache {
  param([string]$MajorMinor = '3.10')
  $toolCache  = Join-Path $InstallDir '_work\_tool'
  $pythonRoot = Join-Path $toolCache 'Python'
  if (Test-Path $pythonRoot) {
    $done = Get-ChildItem -Path $pythonRoot -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like "$MajorMinor.*" -and (Test-Path (Join-Path $pythonRoot ("{0}\x64.complete" -f $_.Name))) }
    if ($done) { Write-Log "Python $MajorMinor already present in the runner tool cache - skipping."; return }
  }

  Write-Log "Resolving latest Python $MajorMinor Windows x64 build from actions/python-versions..."
  $manifest = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/actions/python-versions/main/versions-manifest.json' -UseBasicParsing
  $pattern = "^$([regex]::Escape($MajorMinor))\.\d+$"
  $entry = $manifest |
    Where-Object { $_.version -match $pattern -and ($_.files | Where-Object { $_.platform -eq 'win32' -and $_.arch -eq 'x64' }) } |
    Sort-Object { [version]$_.version } -Descending | Select-Object -First 1
  if (-not $entry) { throw "No Windows x64 build for Python $MajorMinor in the python-versions manifest." }
  $asset = $entry.files | Where-Object { $_.platform -eq 'win32' -and $_.arch -eq 'x64' } | Select-Object -First 1

  $zip     = Join-Path $env:TEMP "python-$($entry.version)-win-x64.zip"
  $extract = Join-Path $env:TEMP "python-$($entry.version)-win-x64"
  Write-Log "Downloading Python $($entry.version)..."
  Invoke-WebRequest -Uri $asset.download_url -OutFile $zip -UseBasicParsing
  if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $extract)

  New-Item -ItemType Directory -Force -Path $toolCache | Out-Null
  $env:AGENT_TOOLSDIRECTORY = $toolCache
  Write-Log "Installing Python $($entry.version) into $toolCache (as SYSTEM)..."
  Push-Location $extract
  try {
    & (Join-Path $extract 'setup.ps1')
    if ($LASTEXITCODE -ne 0) { throw "python-versions setup.ps1 exited with code $LASTEXITCODE." }
  }
  finally { Pop-Location }

  # SYSTEM created the Python tree; grant the runner account (NETWORK SERVICE,
  # well-known SID S-1-5-20) Modify so the action's `pip install` can write site-packages.
  Write-Log 'Granting NETWORK SERVICE modify rights on the tool cache...'
  & icacls $toolCache /grant '*S-1-5-20:(OI)(CI)M' /T /C /Q | Out-Null

  Remove-Item $zip -Force -ErrorAction SilentlyContinue
  Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
  Write-Log "Python $($entry.version) installed into the runner tool cache."
}
Install-PythonToolcache

# --- 0d. Idempotency: skip if a runner service already exists ----------------
$existingService = Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue
if ($existingService) {
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
