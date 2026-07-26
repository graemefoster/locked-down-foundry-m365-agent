<#
  Shared helper: run a PowerShell script ON the in-VNet Linux VM.
  ---------------------------------------------------------------
  Dot-sourced by hooks/predeploy.ps1 and hooks/postdeploy.ps1.

  Why a shim instead of calling Invoke-AzVMRunCommand directly:
    The in-VNet worker VM is now LINUX (see infra/modules/resources/vm-linux.bicep),
    so the 'RunPowerShellScript' command id no longer applies — Linux VMs only accept
    'RunShellScript', whose -Parameter values are POSITIONAL shell arguments rather
    than the named PowerShell parameters our scripts declare.

    The scripts themselves stay in PowerShell (cloud-init installs pwsh), so this
    helper wraps them: it emits a small shell script that materialises the .ps1 on
    the VM via a QUOTED heredoc (no shell expansion of the PowerShell source) and
    then invokes `pwsh -File` with the parameters passed by NAME, exactly as before.

  Nothing secret is embedded: callers pass only endpoints, names and flags. The VM
  authenticates to Foundry with its own managed identity via IMDS.

  Parameter values must be STRINGS. `pwsh -File` only ever passes string arguments, so a
  [switch] parameter on the target script could not be satisfied by `-Name 'true'`. Every
  script invoked this way (scripts/seed-agents.ps1, scripts/publish-teams-runner.ps1)
  declares [string] parameters for exactly that reason; the guard below keeps it that way.
#>

Set-StrictMode -Version Latest

function Invoke-VmPwshScript {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)] [string]    $ResourceGroup,
    [Parameter(Mandatory = $true)] [string]    $VmName,
    [Parameter(Mandatory = $true)] [string]    $ScriptPath,
    [Parameter(Mandatory = $false)][hashtable] $Parameters = @{}
  )

  if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Script not found at '$ScriptPath'."
  }

  $scriptName = [System.IO.Path]::GetFileName($ScriptPath)
  $remotePath = "/tmp/$scriptName"

  # Single-quote each value for the shell. PowerShell parameter names are restricted to
  # word characters, so only the values need escaping ('\'' is the POSIX idiom).
  $argList = foreach ($name in ($Parameters.Keys | Sort-Object)) {
    $value = $Parameters[$name]
    if ($value -isnot [string]) {
      throw "Parameter '-$name' for '$scriptName' is [$($value.GetType().Name)]. Invoke-VmPwshScript passes values through 'pwsh -File', which supplies only strings — declare the target parameter as [string] and pass a string."
    }
    "-$name '$($value -replace "'", "'\''")'"
  }

  # 'PWSH_EOF' is QUOTED so the heredoc body is copied verbatim — the PowerShell source
  # (full of $vars and backticks) must not be interpreted by the shell.
  $wrapper = @(
    '#!/usr/bin/env bash'
    'set -euo pipefail'
    "cat > '$remotePath' <<'PWSH_EOF'"
    (Get-Content -LiteralPath $ScriptPath -Raw)
    'PWSH_EOF'
    "pwsh -NoProfile -NonInteractive -File '$remotePath' $($argList -join ' ')"
    "rm -f '$remotePath'"
  ) -join "`n"

  $tempWrapper = Join-Path ([System.IO.Path]::GetTempPath()) "run-$scriptName-$([guid]::NewGuid().ToString('N')).sh"
  try {
    Set-Content -LiteralPath $tempWrapper -Value $wrapper -Encoding utf8
    return Invoke-AzVMRunCommand `
      -ResourceGroupName $ResourceGroup `
      -VMName $VmName `
      -CommandId 'RunShellScript' `
      -ScriptPath $tempWrapper
  }
  finally {
    Remove-Item -LiteralPath $tempWrapper -Force -ErrorAction SilentlyContinue
  }
}
