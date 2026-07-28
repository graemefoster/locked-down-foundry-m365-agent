<#
  Apply MCP per-agent rate-limit compliance to APIM (control-plane, host-side).
  -----------------------------------------------------------------------------
  Called from hooks/postdeploy.ps1 during `azd up` (AFTER hooks/predeploy.ps1 has seeded the
  agents), and re-usable standalone. It does the SAME two steps as the deploy-compliancy GitHub
  workflow, so a fresh `azd up` leaves a working, compliant agent instead of deny-all:

    1. RESOLVE  scripts/list-agent-appids.ps1 -ResolvePolicyPath mcp/mcp-policy.json joins each
                agent NAME to its live AgentIdentity AppId via Microsoft Graph (az ad sp list).
                This is a CONTROL-PLANE call — no private Foundry endpoint / VM round-trip needed —
                so it runs right here on the azd host.
    2. APPLY    az deployment group create against infra/stages/30-governance/model-gateway/
                apim-mcp-compliance-all.bicep with the resolved policy as the mcpPolicy parameter
                (the same module `azd up`'s main.bicep runs, so the two paths cannot diverge).

  Best-effort by design: the caller wraps this in try/catch and treats a failure as non-fatal, so a
  transient Graph/ARM blip never breaks `azd up`. The resolver THROWS if it resolves zero agents,
  which leaves any previously-applied APIM policy intact rather than revoking all access.

  Required env (Bicep outputs surfaced by azd; run `azd env refresh` if missing):
    AZURE_RESOURCE_GROUP, AZURE_AI_ACCOUNT_NAME, AZURE_AI_PROJECT_NAME,
    MCP_COMPLIANCE_APIM_NAME, MCP_COMPLIANCE_AUDIENCE.

  Caller RBAC: read directory objects (interactive users can; a managed identity / OIDC SP needs
  Directory.Read.All) + Contributor on the resource group (to run the APIM policy deployment).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredEnv {
  param([string]$Name)
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Required env var '$Name' is not set (Bicep output surfaced by azd; run 'azd env refresh')."
  }
  return $value.Trim('"')
}

# Repo root is the parent of this hooks/ directory, regardless of the caller's working directory.
$repoRoot   = Split-Path -Parent $PSScriptRoot
$resolver   = Join-Path $repoRoot 'scripts/list-agent-appids.ps1'
$template   = Join-Path $repoRoot 'infra/stages/30-governance/model-gateway/apim-mcp-compliance-all.bicep'
$policyFile = Join-Path $repoRoot 'mcp/mcp-policy.json'

$rg       = Get-RequiredEnv 'AZURE_RESOURCE_GROUP'
$account  = Get-RequiredEnv 'AZURE_AI_ACCOUNT_NAME'
$project  = Get-RequiredEnv 'AZURE_AI_PROJECT_NAME'
$apimName = Get-RequiredEnv 'MCP_COMPLIANCE_APIM_NAME'
$audience = Get-RequiredEnv 'MCP_COMPLIANCE_AUDIENCE'

foreach ($p in @($resolver, $template, $policyFile)) {
  if (-not (Test-Path -LiteralPath $p)) { throw "Expected file not found: '$p'." }
}

# 1) Resolve name-only mcp-policy.json -> AppId-enriched policy (control plane).
$resolvedPolicy = Join-Path ([System.IO.Path]::GetTempPath()) "mcp-resolved-$([guid]::NewGuid().ToString('N')).json"
try {
  Write-Host "[postdeploy][mcp] Resolving agent names -> AppIds ('$account-$project-<name>-AgentIdentity')."
  # Run the resolver in a child pwsh (fresh runspace) so this script's Set-StrictMode does not
  # leak into it, matching how the deploy-compliancy workflow invokes it. It exits non-zero (and
  # writes no file) if it resolves zero agents, so we never apply a deny-all here.
  pwsh -NoProfile -File $resolver -AccountName $account -ProjectName $project -ResolvePolicyPath $policyFile -OutFile $resolvedPolicy
  if ($LASTEXITCODE -ne 0) { throw "MCP policy resolution failed (exit $LASTEXITCODE)." }
  if (-not (Test-Path -LiteralPath $resolvedPolicy)) {
    throw "Resolver did not produce '$resolvedPolicy'."
  }

  # 2) Apply the resolved policy via the same Bicep module main.bicep uses.
  Write-Host "[postdeploy][mcp] Applying MCP rate-limit policies to APIM '$apimName' (resource group '$rg')."
  az deployment group create `
    --resource-group $rg `
    --name "mcp-compliance-$(Get-Date -Format 'yyyyMMddHHmmss')" `
    --template-file $template `
    --parameters `
      apimName=$apimName `
      mcpAudience=$audience `
      "mcpPolicy=@$resolvedPolicy" `
    --output none
  if ($LASTEXITCODE -ne 0) { throw "az deployment group create (MCP compliance) failed." }
  Write-Host "[postdeploy][mcp] MCP rate-limit policies applied (resolved from mcp/mcp-policy.json)."
}
finally {
  Remove-Item -LiteralPath $resolvedPolicy -Force -ErrorAction SilentlyContinue
}
