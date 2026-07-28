<#
  Shared helper: run a PowerShell script ON the in-VNet Linux VM.
  ---------------------------------------------------------------
  Dot-sourced by hooks/predown.ps1 (the only remaining azd hook that reaches the VM — it
  deregisters the self-hosted GitHub runner before teardown, since the runner PAT lives in
  Key Vault behind a private endpoint and only the VM can read it).

  Why a shim instead of calling `az vm run-command invoke` directly:
    The in-VNet worker VM is now LINUX (see infra/stages/40-runner/resources/vm-linux.bicep),
    so the 'RunPowerShellScript' command id no longer applies — Linux VMs only accept
    'RunShellScript', whose --scripts value is a shell script, not the named PowerShell
    parameters our scripts declare.

    The scripts themselves stay in PowerShell (cloud-init installs pwsh), so this
    helper wraps them: it emits a small shell script that materialises the .ps1 on
    the VM via a QUOTED heredoc (no shell expansion of the PowerShell source) and
    then invokes `pwsh -File` with the parameters passed by NAME, exactly as before.

  Nothing secret is embedded: callers pass only endpoints, names and flags. The VM
  authenticates to Foundry with its own managed identity via IMDS.

  Uses the `az` CLI (`az vm run-command invoke`) so no Az PowerShell modules are required —
  azd already depends on the az CLI for auth. The return value is normalised to the same
  shape the old Invoke-AzVMRunCommand produced (.Value[].Message) so callers are unchanged.

  Parameter values must be STRINGS. `pwsh -File` only ever passes string arguments, so a
  [switch] parameter on the target script could not be satisfied by `-Name 'true'`. Every
  script invoked this way (scripts/deregister-runner.ps1)
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

    # stdout carries the JSON result; stderr (az warnings / errors) is kept separate so a
    # success-with-warning never pollutes the JSON we parse.
    $tempErr = Join-Path ([System.IO.Path]::GetTempPath()) "err-$scriptName-$([guid]::NewGuid().ToString('N')).log"
    try {
      $json = az vm run-command invoke `
        --resource-group $ResourceGroup `
        --name $VmName `
        --command-id 'RunShellScript' `
        --scripts "@$tempWrapper" `
        --output json 2>$tempErr
      if ($LASTEXITCODE -ne 0) {
        $errText = (Get-Content -LiteralPath $tempErr -Raw -ErrorAction SilentlyContinue)
        throw "az vm run-command invoke failed (exit $LASTEXITCODE) on VM '$VmName' (resource group '$ResourceGroup'): $errText"
      }
    }
    finally {
      Remove-Item -LiteralPath $tempErr -Force -ErrorAction SilentlyContinue
    }

    $parsed = ($json | Out-String) | ConvertFrom-Json
    # Normalise to the legacy Invoke-AzVMRunCommand shape: an object with a .Value array
    # whose elements expose .Message (the combined stdout/stderr from RunShellScript).
    return [pscustomobject]@{
      Value = @($parsed.value | ForEach-Object { [pscustomobject]@{ Message = $_.message } })
    }
  }
  finally {
    Remove-Item -LiteralPath $tempWrapper -Force -ErrorAction SilentlyContinue
  }
}
