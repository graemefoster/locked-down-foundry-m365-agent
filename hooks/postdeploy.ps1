<#
  azd postdeploy hook: publish the seeded Foundry agent to Teams / M365
  ---------------------------------------------------------------------
  Runs on the azd host (laptop / CI) AFTER agent seeding. Orchestrates the
  Teams / M365 publish flow described in the Learn article:
    https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot-virtual-network

  Split of responsibilities (strict boundary):
    * The private VM may ONLY call Foundry REST APIs. Steps 1/3/4 hit the PRIVATE
      Foundry endpoint, so they are delegated to the VM inside the VNet via
      `Invoke-AzVMRunCommand` (scripts/publish-teams.ps1) — which does nothing but
      Invoke-RestMethod against Foundry.
    * EVERYTHING else runs HOST-SIDE, outside the VNet, using the caller's Azure
      credentials: the Bot Service Bicep deployment (hooks/bot-service.bicep), the
      Microsoft.BotService RP registration, the APIM policy update, and acquiring the
      USER token used for publishing. No ARM / Bicep / az control-plane work is ever
      executed on the VM.

  IMPORTANT - the caller MUST be signed in as a USER (`Connect-AzAccount` interactively), not a
  service principal / managed identity. The Foundry Microsoft 365 publish step performs
  an on-behalf-of exchange with the caller's token to submit the app to the M365 catalog;
  an app-only token has no user context and the publish call fails server-side with a bare
  HTTP 502. This hook acquires that user token host-side and forwards it to the VM script
  (the VM's own managed identity works for the read/PATCH steps but NOT for publish).

  Flow (repeated per published agent, one Azure Bot Service each):
    1. GetIdentity on the VM      -> agent principal_id (that agent's bot Microsoft App ID)
    2. Create the agent's Azure Bot Service (host) -> botServiceArmId
    4. Publish on the VM under the caller's USER token (Step 3 PATCH + Step 4 publish API)
  Then ONCE, after all bots exist:
    3. (best-effort) set the single path-routed APIM Teams API validate-jwt audience
       allowlist to the SET of every published agent's App ID.

  No-ops unless SEED_ENABLE_TEAMS_PUBLISH == true.

  Required env (Bicep outputs surfaced by azd; run `azd env refresh` if missing):
    AZURE_RESOURCE_GROUP, SEED_AGENTS_VM_NAME, AZURE_AI_PROJECT_ENDPOINT,
    TEAMS_PUBLISH_AGENT_NAMES (CSV; falls back to legacy TEAMS_AGENT_NAME),
    TEAMS_YARP_FQDN, TEAMS_APIM_NAME, TEAMS_APIM_API_NAME,
    TEAMS_TENANT_ID, TEAMS_BOT_NAME, TEAMS_NAME_PREFIX  (+ AZURE_SUBSCRIPTION_ID, an azd built-in)
  Optional publish metadata env: TEAMS_PUBLISH_SCOPE,
    TEAMS_APP_VERSION, TEAMS_SHORT_DESCRIPTION, TEAMS_FULL_DESCRIPTION,
    TEAMS_DEVELOPER_NAME, TEAMS_DEVELOPER_WEBSITE_URL, TEAMS_PRIVACY_URL,
    TEAMS_TERMS_OF_USE_URL, TEAMS_LOG_ANALYTICS_ID (workspace for bot diagnostics)
  Each published agent's display name is '<TEAMS_NAME_PREFIX>-<agentName>' (the env's
  unique suffix), so entries from different deployments stay distinct in the tenant catalog.

  Caller RBAC: VM run-command invoke (e.g. Virtual Machine Contributor) + Azure
  Bot Service Contributor (create the bot) + Foundry User on the project. The caller
  must be a USER identity (see the on-behalf-of note above), not a service principal.

  Requires: Az.Compute, Az.Accounts, Az.Resources modules.
#>
#Requires -Modules Az.Compute, Az.Accounts, Az.Resources
$ErrorActionPreference = 'Stop'

$enableTeams = [Environment]::GetEnvironmentVariable('SEED_ENABLE_TEAMS_PUBLISH')
if ($null -eq $enableTeams) { $enableTeams = 'false' }
$enableTeams = $enableTeams.Trim('"').ToLowerInvariant()
if ($enableTeams -ne 'true') {
  Write-Host '[postdeploy] SEED_ENABLE_TEAMS_PUBLISH is not true - skipping Teams / M365 publish.'
  return
}

function Get-RequiredEnv {
  param([string]$Name)
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "[postdeploy] Required environment variable '$Name' is not set. Run 'azd provision' (then 'azd env refresh') so the Bicep outputs are available."
  }
  return $value
}
function Get-OptionalEnv {
  param([string]$Name, [string]$Default = '')
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
  return $value.Trim('"')
}

# ARM control-plane calls to APIM v2 entity sub-resources can intermittently return
# HTTP 502/503/504. Retry those transient failures with backoff.
function Invoke-AzRestWithRetry {
  param([string]$Method, [string]$Path, [string]$Payload, [int]$MaxAttempts = 5)
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $params = @{ Method = $Method; Path = $Path }
    if ($Payload) { $params.Payload = $Payload }
    $response = Invoke-AzRestMethod @params
    if ($response.StatusCode -lt 400) {
      return $response
    }
    $transient = $response.StatusCode -in 502, 503, 504
    if ($transient -and $attempt -lt $MaxAttempts) {
      $wait = [math]::Min(30, [math]::Pow(2, $attempt))
      Write-Host "[postdeploy] ARM call returned HTTP $($response.StatusCode) (attempt $attempt/$MaxAttempts) - retrying in ${wait}s..."
      Start-Sleep -Seconds $wait
      continue
    }
    return $response
  }
}

$resourceGroup   = Get-RequiredEnv 'AZURE_RESOURCE_GROUP'
$vmName          = Get-RequiredEnv 'SEED_AGENTS_VM_NAME'
$projectEndpoint = Get-RequiredEnv 'AZURE_AI_PROJECT_ENDPOINT'
$agentNamesCsv   = Get-OptionalEnv 'TEAMS_PUBLISH_AGENT_NAMES'
if ([string]::IsNullOrWhiteSpace($agentNamesCsv)) {
  # Back-compat: fall back to the legacy single-agent output.
  $agentNamesCsv = Get-RequiredEnv 'TEAMS_AGENT_NAME'
}
$agentNames = @($agentNamesCsv.Trim('"').Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($agentNames.Count -eq 0) {
  throw '[postdeploy] No agents to publish (TEAMS_PUBLISH_AGENT_NAMES / TEAMS_AGENT_NAME are empty).'
}
$yarpFqdn        = Get-RequiredEnv 'TEAMS_YARP_FQDN'
$apimName        = Get-RequiredEnv 'TEAMS_APIM_NAME'
$apimApiName     = Get-RequiredEnv 'TEAMS_APIM_API_NAME'
$tenantId        = Get-RequiredEnv 'TEAMS_TENANT_ID'
$botName         = Get-RequiredEnv 'TEAMS_BOT_NAME'
$logAnalyticsId  = Get-OptionalEnv 'TEAMS_LOG_ANALYTICS_ID'

$subscriptionId  = Get-OptionalEnv 'AZURE_SUBSCRIPTION_ID'
if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
  $ctx = Get-AzContext -ErrorAction SilentlyContinue
  if ($ctx) { $subscriptionId = $ctx.Subscription.Id }
}

$namePrefix      = Get-OptionalEnv 'TEAMS_NAME_PREFIX'
$publishScope    = Get-OptionalEnv 'TEAMS_PUBLISH_SCOPE' 'Shared'
$appVersion      = Get-OptionalEnv 'TEAMS_APP_VERSION' '1.0.0'
$shortDesc       = Get-OptionalEnv 'TEAMS_SHORT_DESCRIPTION' 'Foundry M365 agent'
$fullDesc        = Get-OptionalEnv 'TEAMS_FULL_DESCRIPTION' 'A Foundry agent published to Microsoft 365 from a locked-down virtual network.'
$developerName   = Get-OptionalEnv 'TEAMS_DEVELOPER_NAME' 'Azure Developer'
$developerUrl    = Get-OptionalEnv 'TEAMS_DEVELOPER_WEBSITE_URL' 'https://azure.microsoft.com'
$privacyUrl      = Get-OptionalEnv 'TEAMS_PRIVACY_URL' 'https://privacy.microsoft.com'
$termsUrl        = Get-OptionalEnv 'TEAMS_TERMS_OF_USE_URL' 'https://www.microsoft.com/legal/terms-of-use'

function Get-DisplayName {
  param([string]$AgentName)
  if ([string]::IsNullOrWhiteSpace($namePrefix)) { return $AgentName }
  return "$namePrefix-$AgentName"
}

$repoRoot      = Split-Path $PSScriptRoot -Parent
$publishScript = Join-Path $repoRoot 'scripts/publish-teams.ps1'
$botTemplate   = Join-Path $PSScriptRoot 'bot-service.bicep'
foreach ($f in @($publishScript, $botTemplate)) {
  if (-not (Test-Path $f)) { throw "[postdeploy] Required file not found: '$f'." }
}

# Runs the .ps1 under pwsh on the LINUX worker VM (RunShellScript + a heredoc shim).
. (Join-Path $PSScriptRoot 'vm-run-command.ps1')

# Runs scripts/publish-teams.ps1 on the VM and returns its combined stdout.
function Invoke-OnVm {
  param([hashtable]$ScriptParameters)
  $result = Invoke-VmPwshScript `
    -ResourceGroup $resourceGroup `
    -VmName $vmName `
    -ScriptPath $publishScript `
    -Parameters $ScriptParameters

  return (($result.Value | ForEach-Object { $_.Message }) -join "`n")
}


Write-Host '[postdeploy] Registering Microsoft.BotService resource provider (idempotent)...'
Register-AzResourceProvider -ProviderNamespace Microsoft.BotService | Out-Null

# --- Acquire a USER (delegated) token (used by every publish-teams call on the VM) ---
Write-Host '[postdeploy] Acquiring a user access token (aud https://ai.azure.com)...'
$tokenResult = Get-AzAccessToken -ResourceUrl 'https://ai.azure.com'
$publishToken = $tokenResult.Token
if ([string]::IsNullOrWhiteSpace($publishToken)) {
  throw "[postdeploy] Failed to acquire an access token. Run 'Connect-AzAccount' as a user (not a service principal)."
}
# Sanity-check that this is a delegated user token, not an app-only token.
try {
  $payloadSeg = $publishToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
  switch ($payloadSeg.Length % 4) { 2 { $payloadSeg += '==' } 3 { $payloadSeg += '=' } }
  $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payloadSeg)) | ConvertFrom-Json
  $claimNames = $claims.PSObject.Properties.Name
  if ($claims.idtyp -eq 'app' -or -not ($claimNames -contains 'upn' -or $claimNames -contains 'unique_name')) {
    Write-Warning "[postdeploy] The acquired token looks app-only (idtyp='$($claims.idtyp)'). Foundry's publish OBO step needs a USER token, so publish may fail with HTTP 502. Run 'Connect-AzAccount' interactively as a user."
  }
  else {
    Write-Host "[postdeploy] Using delegated user token (upn=$($claims.upn))."
  }
}
catch {
  Write-Warning "[postdeploy] Could not decode the access token to verify it is a user token: $($_.Exception.Message)"
}

# =====================================================================================
# Phase A: per agent, read its identity and create its Azure Bot Service (host-side ARM).
# Collect each agent's App ID so we can build the APIM audience allowlist in one shot.
# =====================================================================================
$published = @()   # { Name; PrincipalId; BotArmId; BotName }

foreach ($agentName in $agentNames) {
  $agentBotName = "$botName-$agentName"
  $botEndpoint  = "https://$yarpFqdn/teams/$agentName"
  $displayName  = Get-DisplayName $agentName

  # --- Step 1: get the agent identity (on the VM) ---
  Write-Host "[postdeploy] ($agentName) Step 1: reading agent identity on VM '$vmName'..."
  $identityOut = Invoke-OnVm -ScriptParameters @{
    Mode                   = 'GetIdentity'
    FoundryProjectEndpoint = $projectEndpoint
    AgentName              = $agentName
    AccessToken            = $publishToken
  }
  Write-Host "----- publish-teams (GetIdentity: $agentName) output -----"
  Write-Host $identityOut
  Write-Host '----------------------------------------------'
  if ($identityOut -notmatch '\[publish-teams\] Done\.') {
    throw "[postdeploy] GetIdentity did not complete successfully for '$agentName'. See VM output above."
  }
  $principalId = ([regex]'PRINCIPAL_ID=([0-9a-fA-F-]{36})').Match($identityOut).Groups[1].Value
  if ([string]::IsNullOrWhiteSpace($principalId)) {
    throw "[postdeploy] Could not parse the agent principal_id for '$agentName' from the VM output."
  }
  Write-Host "[postdeploy] ($agentName) principal_id (bot App ID): $principalId"

  # --- Step 2: create the agent's Azure Bot Service (host-side ARM) ---
  Write-Host "[postdeploy] ($agentName) Step 2: creating Azure Bot Service '$agentBotName' (endpoint $botEndpoint)..."
  $deployment = New-AzResourceGroupDeployment `
    -ResourceGroupName $resourceGroup `
    -Name "bot-$agentName" `
    -TemplateFile $botTemplate `
    -botName $agentBotName `
    -displayName $displayName `
    -msaAppId $principalId `
    -tenantId $tenantId `
    -endpoint $botEndpoint `
    -logAnalyticsWorkspaceId $logAnalyticsId `
    -ErrorAction Stop
  $botArmId = $deployment.Outputs['botServiceArmId'].Value
  if ([string]::IsNullOrWhiteSpace($botArmId)) {
    throw "[postdeploy] Bot Service deployment did not return botServiceArmId for '$agentName'."
  }
  Write-Host "[postdeploy] ($agentName) Bot Service ARM ID: $botArmId"

  $published += [pscustomobject]@{ Name = $agentName; PrincipalId = $principalId; BotArmId = $botArmId; BotName = $agentBotName }
}

# =====================================================================================
# Phase B (best-effort): set the single path-routed APIM Teams API validate-jwt audience
# allowlist to the SET of every published agent's App ID.
# =====================================================================================
try {
  $appIds = @($published | ForEach-Object { $_.PrincipalId } | Sort-Object -Unique)
  Write-Host "[postdeploy] Setting APIM validate-jwt audience allowlist to $($appIds.Count) bot App ID(s)..."
  $policyPath = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimName/apis/$apimApiName/policies/policy?api-version=2024-05-01"

  $get = Invoke-AzRestWithRetry -Method GET -Path "${policyPath}&format=rawxml"
  $current = ''
  if ($get.StatusCode -lt 400) {
    $parsed = $get.Content | ConvertFrom-Json
    $current = $parsed.properties.value
  }

  if ($get.StatusCode -ge 400) {
    Write-Warning '[postdeploy] Could not read the current APIM policy after retries; leaving issuer-only validation.'
  }
  elseif (-not [string]::IsNullOrWhiteSpace($current) -and $current -match '</issuers>') {
    $audienceEntries = ($appIds | ForEach-Object { "<audience>$_</audience>" }) -join ''
    $audiences = "<audiences>$audienceEntries</audiences>"
    if ($current -match '(?s)<audiences>.*?</audiences>') {
      $updated = $current -replace '(?s)<audiences>.*?</audiences>', $audiences
    }
    else {
      $updated = $current -replace '<issuers>', "$audiences<issuers>"
    }
    if ($updated -eq $current) {
      Write-Host '[postdeploy] APIM audience allowlist already up to date - skipping.'
    }
    else {
      $bodyObj = @{ properties = @{ format = 'rawxml'; value = $updated } } | ConvertTo-Json -Depth 10 -Compress
      $put = Invoke-AzRestWithRetry -Method PUT -Path $policyPath -Payload $bodyObj
      if ($put.StatusCode -lt 400) { Write-Host "[postdeploy] APIM audience allowlist set to: $($appIds -join ', ')." }
      else { Write-Warning '[postdeploy] APIM audience allowlist PUT failed after retries. Re-run `azd hooks run postdeploy` to complete the pin.' }
    }
  }
  else {
    Write-Warning '[postdeploy] Current APIM policy did not contain the expected <issuers> element; leaving issuer-only validation.'
  }
}
catch {
  Write-Warning "[postdeploy] APIM audience allowlist update failed (non-fatal): $($_.Exception.Message)"
}

# =====================================================================================
# Phase C: per agent, enable activity protocol + publish to Teams / M365 (on the VM).
# =====================================================================================
foreach ($p in $published) {
  $agentName   = $p.Name
  $displayName = Get-DisplayName $agentName
  Write-Host "[postdeploy] ($agentName) Steps 3+4: publishing to Teams / M365 (scope=$publishScope)..."
  $publishOut = Invoke-OnVm -ScriptParameters @{
    Mode                   = 'Publish'
    FoundryProjectEndpoint = $projectEndpoint
    AgentName              = $agentName
    BotServiceArmId        = $p.BotArmId
    AccessToken            = $publishToken
    DisplayName            = $displayName
    PublishScope           = $publishScope
    AppVersion             = $appVersion
    ShortDescription       = $shortDesc
    FullDescription        = $fullDesc
    DeveloperName          = $developerName
    DeveloperWebsiteUrl    = $developerUrl
    PrivacyUrl             = $privacyUrl
    TermsOfUseUrl          = $termsUrl
  }
  Write-Host "----- publish-teams (Publish: $agentName) output -----"
  Write-Host $publishOut
  Write-Host '------------------------------------------'
  if ($publishOut -notmatch '\[publish-teams\] Done\.') {
    throw "[postdeploy] Agent publish did not complete successfully for '$agentName'. See VM output above."
  }
  Write-Host "[postdeploy] ($agentName) Teams / M365 publish complete. Bot: $($p.BotName)."
}

Write-Host "[postdeploy] All agents published (scope=$publishScope): $($published.Name -join ', ')."
Write-Host '[postdeploy] Find the agents in the Teams / M365 Copilot store (Shared -> "Your agents"; Tenant -> "Built by your org" after admin approval).'
