<#
  Publish seeded Foundry agents to Teams / M365 — FROM THE IN-VNET RUNNER
  -----------------------------------------------------------------------
  Runs ON the locked-down VM, executed by the self-hosted GitHub Actions runner
  (.github/workflows/deploy-vnet.yml and deploy-test-agent-one.yml, via the
  .github/actions/publish-teams composite action). This is now the ONLY Teams / M365
  publish path — azd runs nothing after provision. Everything runs locally on the VM
  as the VM's system-assigned managed identity, except the Microsoft 365 publish call
  (see the token note below).

  Because the runner IS the VM (a trusted, gated Posture A worker), it can:
    * call the PRIVATE Foundry endpoint directly (IMDS / az MI token), and
    * do the Azure Bot Service ARM deployment itself (the VM MI is granted
      Contributor over the resource group when the runner is installed —
      infra/stages/40-runner/rbac/vm-contributor-role.bicep).

  Per agent it: (1) reads the agent identity, (2) creates that agent's Azure Bot
  Service, (3) enables the activity protocol + publishes to Microsoft 365.

  TOKEN NOTE: the Microsoft 365 publish step performs an on-behalf-of style submission
  "on your behalf" to the M365 catalog and rejects an app-only / managed-identity token
  with a bare HTTP 502. The publish-teams composite action therefore acquires a delegated
  USER token (device-code sign-in) and forwards it via -PublishAccessToken, which is used
  ONLY for the publish call. When no user token is supplied this script falls back to the
  VM MI token (the app-only path, expected to 502 at Step 4) so the behaviour can be
  confirmed in place.

  NOTE: the APIM validate-jwt audience pin (formerly the postdeploy hook's Phase B) is NOT
  performed by this path — it focuses on the publish flow itself.

  PowerShell 7 (pwsh) — cloud-init installs it on the Linux worker VM.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]  [string]$FoundryProjectEndpoint,
  [Parameter(Mandatory = $true)]  [string]$ResourceGroup,
  # Comma-separated agent names to publish (one bot each, endpoint /teams/<agentName>).
  [Parameter(Mandatory = $true)]  [string]$AgentNames,
  # Public YARP FQDN — the Azure Bot Service messaging endpoint host.
  [Parameter(Mandatory = $true)]  [string]$YarpFqdn,
  # Entra tenant the single-tenant bot registration lives in.
  [Parameter(Mandatory = $true)]  [string]$TenantId,
  # Base Azure Bot Service name; each bot is '<BotName>-<agentName>'.
  [Parameter(Mandatory = $true)]  [string]$BotName,
  # Prefix onto each published display name (the env's unique suffix). Optional.
  [Parameter(Mandatory = $false)] [string]$NamePrefix = '',
  # Log Analytics workspace resource ID for bot diagnostics. Optional.
  [Parameter(Mandatory = $false)] [string]$LogAnalyticsWorkspaceId = '',
  [Parameter(Mandatory = $false)] [string]$PublishScope = 'Shared',
  # Delegated USER token used ONLY for the Microsoft 365 publish call (Step 4),
  # which rejects an app-only / managed-identity token. When empty, the MI token
  # is used for publish too (the app-only test path).
  [Parameter(Mandatory = $false)] [string]$PublishAccessToken = '',
  # Publish metadata (the M365 app listing). Optional pass-throughs: when NOT supplied
  # here they are not forwarded, so publish-teams.ps1's defaults apply — that script is
  # the single source of truth for these values. Only set them to override those defaults.
  [Parameter(Mandatory = $false)] [string]$AppVersion,
  [Parameter(Mandatory = $false)] [string]$ShortDescription,
  [Parameter(Mandatory = $false)] [string]$FullDescription,
  [Parameter(Mandatory = $false)] [string]$DeveloperName,
  [Parameter(Mandatory = $false)] [string]$DeveloperWebsiteUrl,
  [Parameter(Mandatory = $false)] [string]$PrivacyUrl,
  [Parameter(Mandatory = $false)] [string]$TermsOfUseUrl
)
$ErrorActionPreference = 'Stop'

$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')

$repoRoot      = Split-Path $PSScriptRoot -Parent
$publishScript = Join-Path $PSScriptRoot 'publish-teams.ps1'
$botTemplate   = Join-Path $repoRoot 'hooks/bot-service.bicep'
foreach ($f in @($publishScript, $botTemplate)) {
  if (-not (Test-Path $f)) { throw "[publish-runner] Required file not found: '$f'." }
}

$agents = @($AgentNames.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($agents.Count -eq 0) { throw '[publish-runner] No agent names supplied.' }

function Get-DisplayName {
  param([string]$AgentName)
  if ([string]::IsNullOrWhiteSpace($NamePrefix)) { return $AgentName }
  return "$NamePrefix-$AgentName"
}

# --- Acquire the VM managed-identity token for the Foundry (ai.azure.com) audience ---
# Deliberately app-only (MI). The host-side hook uses a delegated user token; this path
# tests whether the MI token is accepted by the publish API.
Write-Host '[publish-runner] Acquiring VM managed-identity token (aud https://ai.azure.com)...'
$token = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
  throw "[publish-runner] Failed to acquire a managed-identity token. Ensure 'az login --identity' ran on the runner."
}
# Decode + report the token type so the log clearly records this is an app-only token.
try {
  $seg = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
  switch ($seg.Length % 4) { 2 { $seg += '==' } 3 { $seg += '=' } }
  $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($seg)) | ConvertFrom-Json
  Write-Host "[publish-runner] Token idtyp='$($claims.idtyp)' appid='$($claims.appid)' (app-only = no user context)."
}
catch {
  Write-Warning "[publish-runner] Could not decode the access token: $($_.Exception.Message)"
}

# --- Select the token for the Microsoft 365 publish call (Step 4) ---
# The publish API rejects app-only / MI tokens (HTTP 502), so prefer the delegated
# USER token supplied via the device-code sign-in. When none is supplied, fall back
# to the MI token (the app-only test path, which is expected to 502 at Step 4).
$publishToken = if ([string]::IsNullOrWhiteSpace($PublishAccessToken)) { $token } else { $PublishAccessToken }
if (-not [string]::IsNullOrWhiteSpace($PublishAccessToken)) {
  try {
    $pseg = $PublishAccessToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($pseg.Length % 4) { 2 { $pseg += '==' } 3 { $pseg += '=' } }
    $pclaims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pseg)) | ConvertFrom-Json
    Write-Host "[publish-runner] Publish token idtyp='$($pclaims.idtyp)' upn='$($pclaims.upn)$($pclaims.unique_name)' (delegated user token for the M365 publish)."
  }
  catch { Write-Warning "[publish-runner] Could not decode the publish token: $($_.Exception.Message)" }
}
else {
  Write-Host '[publish-runner] No delegated user token supplied; using the app-only MI token for the publish call (expected to 502).'
}

# Forward only the publish-metadata overrides explicitly supplied to THIS script, so
# publish-teams.ps1 stays the single source of truth for their defaults (no duplication).
$publishMetadata = @{}
foreach ($k in 'AppVersion', 'ShortDescription', 'FullDescription', 'DeveloperName', 'DeveloperWebsiteUrl', 'PrivacyUrl', 'TermsOfUseUrl') {
  if ($PSBoundParameters.ContainsKey($k)) { $publishMetadata[$k] = $PSBoundParameters[$k] }
}

foreach ($agentName in $agents) {
  $agentBotName = "$BotName-$agentName"
  $botEndpoint  = "https://$YarpFqdn/teams/$agentName"
  $displayName  = Get-DisplayName $agentName

  # --- Step 1: get the agent identity (principal_id = the bot Microsoft App ID) ---
  Write-Host "[publish-runner] ($agentName) Step 1: reading agent identity..."
  $identityOut = & $publishScript `
    -Mode GetIdentity `
    -FoundryProjectEndpoint $FoundryProjectEndpoint `
    -AgentName $agentName `
    -AccessToken $token *>&1 | Out-String
  Write-Host $identityOut
  if ($identityOut -notmatch '\[publish-teams\] Done\.') {
    throw "[publish-runner] GetIdentity did not complete for '$agentName'."
  }
  $principalId = ([regex]'PRINCIPAL_ID=([0-9a-fA-F-]{36})').Match($identityOut).Groups[1].Value
  if ([string]::IsNullOrWhiteSpace($principalId)) {
    throw "[publish-runner] Could not parse principal_id for '$agentName'."
  }
  Write-Host "[publish-runner] ($agentName) principal_id (bot App ID): $principalId"

  # --- Step 2: create the agent's Azure Bot Service (ARM, as the VM MI / Contributor) ---
  Write-Host "[publish-runner] ($agentName) Step 2: creating Azure Bot Service '$agentBotName' (endpoint $botEndpoint)..."
  $botArmId = az deployment group create `
    --resource-group $ResourceGroup `
    --name "bot-$agentName" `
    --template-file $botTemplate `
    --parameters `
      botName=$agentBotName `
      displayName="$displayName" `
      msaAppId=$principalId `
      tenantId=$TenantId `
      endpoint=$botEndpoint `
      logAnalyticsWorkspaceId=$LogAnalyticsWorkspaceId `
    --query 'properties.outputs.botServiceArmId.value' -o tsv
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($botArmId)) {
    throw "[publish-runner] Bot Service deployment failed for '$agentName' (exit $LASTEXITCODE)."
  }
  Write-Host "[publish-runner] ($agentName) Bot Service ARM ID: $botArmId"

  # --- Steps 3+4: enable activity protocol + publish to Microsoft 365 ---
  Write-Host "[publish-runner] ($agentName) Steps 3+4: publishing to Teams / M365 (scope=$PublishScope)..."
  $publishOut = & $publishScript `
    -Mode Publish `
    -FoundryProjectEndpoint $FoundryProjectEndpoint `
    -AgentName $agentName `
    -BotServiceArmId $botArmId `
    -AccessToken $publishToken `
    -DisplayName $displayName `
    -PublishScope $PublishScope `
    @publishMetadata *>&1 | Out-String
  Write-Host $publishOut
  if ($publishOut -notmatch '\[publish-teams\] Done\.') {
    throw "[publish-runner] Publish did not complete for '$agentName'."
  }
  Write-Host "[publish-runner] ($agentName) Teams / M365 publish complete. Bot: $agentBotName."
}

Write-Host "[publish-runner] All agents published (scope=$PublishScope): $($agents -join ', ')."
