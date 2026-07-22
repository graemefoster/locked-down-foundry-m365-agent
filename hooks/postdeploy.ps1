<#
  azd postdeploy hook: publish the seeded Foundry agent to Teams / M365
  ---------------------------------------------------------------------
  Runs on the azd host (laptop / CI) AFTER agent seeding. Orchestrates the
  Teams / M365 publish flow described in the Learn article:
    https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot-virtual-network

  Split of responsibilities (strict boundary):
    * The private VM may ONLY call Foundry REST APIs. Steps 1/3/4 hit the PRIVATE
      Foundry endpoint, so they are delegated to the VM inside the VNet via
      `az vm run-command` (scripts/publish-teams.ps1) — which does nothing but
      Invoke-RestMethod against Foundry.
    * EVERYTHING else runs HOST-SIDE, outside the VNet, using the caller's Azure
      credentials: the Bot Service Bicep deployment (hooks/bot-service.bicep), the
      Microsoft.BotService RP registration, the APIM policy update, and acquiring the
      USER token used for publishing. No ARM / Bicep / az control-plane work is ever
      executed on the VM.

  IMPORTANT - the caller MUST be signed in as a USER (`az login` interactively), not a
  service principal / managed identity. The Foundry Microsoft 365 publish step performs
  an on-behalf-of exchange with the caller's token to submit the app to the M365 catalog;
  an app-only token has no user context and the publish call fails server-side with a bare
  HTTP 502. This hook acquires that user token host-side and forwards it to the VM script
  (the VM's own managed identity works for the read/PATCH steps but NOT for publish).

  Flow:
    1. GetIdentity on the VM      -> agent principal_id (the bot Microsoft App ID)
    2. Create the Azure Bot Service (host)  -> botServiceArmId
    3. (best-effort) pin the APIM Teams API validate-jwt audience to the App ID
    4. Publish on the VM under the caller's USER token (Step 3 PATCH + Step 4 publish API)

  No-ops unless SEED_ENABLE_TEAMS_PUBLISH == true.

  Required env (Bicep outputs surfaced by azd; run `azd env refresh` if missing):
    AZURE_RESOURCE_GROUP, SEED_AGENTS_VM_NAME, AZURE_AI_PROJECT_ENDPOINT,
    TEAMS_AGENT_NAME, TEAMS_YARP_FQDN, TEAMS_APIM_NAME, TEAMS_APIM_API_NAME,
    TEAMS_TENANT_ID, TEAMS_BOT_NAME  (+ AZURE_SUBSCRIPTION_ID, an azd built-in)
  Optional publish metadata env: TEAMS_BOT_DISPLAY_NAME, TEAMS_PUBLISH_SCOPE,
    TEAMS_APP_VERSION, TEAMS_SHORT_DESCRIPTION, TEAMS_FULL_DESCRIPTION,
    TEAMS_DEVELOPER_NAME, TEAMS_DEVELOPER_WEBSITE_URL, TEAMS_PRIVACY_URL,
    TEAMS_TERMS_OF_USE_URL, TEAMS_LOG_ANALYTICS_ID (workspace for bot diagnostics)

  Caller RBAC: VM run-command invoke (e.g. Virtual Machine Contributor) + Azure
  Bot Service Contributor (create the bot) + Foundry User on the project. The caller
  must be a USER identity (see the on-behalf-of note above), not a service principal.
#>
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

$resourceGroup   = Get-RequiredEnv 'AZURE_RESOURCE_GROUP'
$vmName          = Get-RequiredEnv 'SEED_AGENTS_VM_NAME'
$projectEndpoint = Get-RequiredEnv 'AZURE_AI_PROJECT_ENDPOINT'
$agentName       = Get-RequiredEnv 'TEAMS_AGENT_NAME'
$yarpFqdn        = Get-RequiredEnv 'TEAMS_YARP_FQDN'
$apimName        = Get-RequiredEnv 'TEAMS_APIM_NAME'
$apimApiName     = Get-RequiredEnv 'TEAMS_APIM_API_NAME'
$tenantId        = Get-RequiredEnv 'TEAMS_TENANT_ID'
$botName         = Get-RequiredEnv 'TEAMS_BOT_NAME'
$logAnalyticsId  = Get-OptionalEnv 'TEAMS_LOG_ANALYTICS_ID'

$subscriptionId  = Get-OptionalEnv 'AZURE_SUBSCRIPTION_ID'
if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
  $subscriptionId = (az account show --query id -o tsv)
}

$displayName     = Get-OptionalEnv 'TEAMS_BOT_DISPLAY_NAME' $agentName
$publishScope    = Get-OptionalEnv 'TEAMS_PUBLISH_SCOPE' 'Shared'
$appVersion      = Get-OptionalEnv 'TEAMS_APP_VERSION' '1.0.0'
$shortDesc       = Get-OptionalEnv 'TEAMS_SHORT_DESCRIPTION' 'Foundry M365 agent'
$fullDesc        = Get-OptionalEnv 'TEAMS_FULL_DESCRIPTION' 'A Foundry agent published to Microsoft 365 from a locked-down virtual network.'
$developerName   = Get-OptionalEnv 'TEAMS_DEVELOPER_NAME' 'Azure Developer'
$developerUrl    = Get-OptionalEnv 'TEAMS_DEVELOPER_WEBSITE_URL' 'https://azure.microsoft.com'
$privacyUrl      = Get-OptionalEnv 'TEAMS_PRIVACY_URL' 'https://privacy.microsoft.com'
$termsUrl        = Get-OptionalEnv 'TEAMS_TERMS_OF_USE_URL' 'https://www.microsoft.com/legal/terms-of-use'

# In this topology the bot messaging endpoint is the PUBLIC YARP proxy + '/teams',
# which forwards to APIM -> the agent activityProtocol private endpoint.
$botEndpoint = "https://$yarpFqdn/teams"

$repoRoot      = Split-Path $PSScriptRoot -Parent
$publishScript = Join-Path $repoRoot 'scripts/publish-teams.ps1'
# bot-service.bicep lives beside this hook (hooks/), deployed HOST-SIDE. It is deliberately
# NOT in scripts/ — that folder is for scripts executed ON the private VM, which may ONLY
# call Foundry REST APIs. All ARM / Bicep / APIM control-plane work runs here, outside the VNet.
$botTemplate   = Join-Path $PSScriptRoot 'bot-service.bicep'
foreach ($f in @($publishScript, $botTemplate)) {
  if (-not (Test-Path $f)) { throw "[postdeploy] Required file not found: '$f'." }
}

# Runs scripts/publish-teams.ps1 on the VM and returns its combined stdout.
function Invoke-OnVm {
  param([string[]]$ScriptParameters)
  $azArgs = @(
    'vm', 'run-command', 'invoke',
    '--command-id', 'RunPowerShellScript',
    '--name', $vmName,
    '--resource-group', $resourceGroup,
    '--scripts', "@$publishScript",
    '--parameters'
  ) + $ScriptParameters + @('--output', 'json')

  $raw = az @azArgs
  if ($LASTEXITCODE -ne 0) {
    Write-Host $raw
    throw "[postdeploy] 'az vm run-command invoke' failed with exit code $LASTEXITCODE."
  }
  $result = $raw | ConvertFrom-Json
  return (($result.value | ForEach-Object { $_.message }) -join "`n")
}

Write-Host '[postdeploy] Registering Microsoft.BotService resource provider (idempotent)...'
az provider register --namespace Microsoft.BotService --only-show-errors | Out-Null

# --- Step 1: get the agent identity (on the VM) ---
Write-Host "[postdeploy] Step 1: reading agent '$agentName' identity on VM '$vmName'..."
$identityOut = Invoke-OnVm -ScriptParameters @(
  'Mode=GetIdentity',
  "FoundryProjectEndpoint=$projectEndpoint",
  "AgentName=$agentName"
)
Write-Host '----- publish-teams (GetIdentity) output -----'
Write-Host $identityOut
Write-Host '----------------------------------------------'
if ($identityOut -notmatch '\[publish-teams\] Done\.') {
  throw '[postdeploy] GetIdentity did not complete successfully. See VM output above.'
}
$principalId = ([regex]'PRINCIPAL_ID=([0-9a-fA-F-]{36})').Match($identityOut).Groups[1].Value
if ([string]::IsNullOrWhiteSpace($principalId)) {
  throw '[postdeploy] Could not parse the agent principal_id from the VM output.'
}
Write-Host "[postdeploy] Agent principal_id (bot App ID): $principalId"

# --- Step 2: create the Azure Bot Service (host-side ARM) ---
Write-Host "[postdeploy] Step 2: creating Azure Bot Service '$botName' (endpoint $botEndpoint)..."
$botArmId = az deployment group create `
  --resource-group $resourceGroup `
  --template-file $botTemplate `
  --parameters `
    botName=$botName `
    displayName="$displayName" `
    msaAppId=$principalId `
    tenantId=$tenantId `
    endpoint=$botEndpoint `
    logAnalyticsWorkspaceId=$logAnalyticsId `
  --query 'properties.outputs.botServiceArmId.value' -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($botArmId)) {
  throw "[postdeploy] Bot Service deployment failed (exit $LASTEXITCODE)."
}
Write-Host "[postdeploy] Bot Service ARM ID: $botArmId"

# --- Step 3 (best-effort): pin the APIM validate-jwt audience to the bot App ID ---
# The APIM Teams API ships with issuer-only validation (botAppId unknown at provision time).
# Now that we know the App ID, tighten the policy to also validate the audience. Best-effort:
# a failure here does NOT block publishing (issuer validation + IP restriction remain active).
try {
  Write-Host '[postdeploy] Pinning APIM validate-jwt audience to the bot App ID...'
  $policyUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimName/apis/$apimApiName/policies/policy?api-version=2024-05-01"
  # Read the RAW policy XML. `-o tsv` on a multi-line value makes PowerShell capture
  # stdout as a string ARRAY, so re-join it into a single string - otherwise the PUT
  # body serialises `value` as a JSON array and APIM rejects it ("Data at the root
  # level is invalid. Line 1, position 1").
  $currentLines = az rest --method get --url "$policyUrl&format=rawxml" --query 'properties.value' -o tsv
  $current = ($currentLines -join "`n")
  if (-not [string]::IsNullOrWhiteSpace($current) -and $current -match '</issuers>') {
    if ($current -match [regex]::Escape($principalId)) {
      Write-Host '[postdeploy] APIM audience already pinned - skipping.'
    }
    else {
      $audiences = "<audiences><audience>$principalId</audience></audiences>"
      # validate-jwt requires child order openid-config -> audiences -> issuers ->
      # required-claims, so insert BEFORE <issuers> (not after </issuers>).
      $updated = $current -replace '<issuers>', "$audiences<issuers>"
      $bodyObj = @{ properties = @{ format = 'rawxml'; value = $updated } } | ConvertTo-Json -Depth 10 -Compress
      $tmp = New-TemporaryFile
      Set-Content -Path $tmp -Value $bodyObj -Encoding utf8
      az rest --method put --url $policyUrl --headers 'Content-Type=application/json' --body "@$tmp" --only-show-errors | Out-Null
      Remove-Item $tmp -Force
      if ($LASTEXITCODE -eq 0) { Write-Host '[postdeploy] APIM audience pinned.' }
      else { Write-Warning '[postdeploy] APIM audience pin PUT returned non-zero; leaving issuer-only validation.' }
    }
  }
  else {
    Write-Warning '[postdeploy] Could not read the current APIM policy; leaving issuer-only validation.'
  }
}
catch {
  Write-Warning "[postdeploy] APIM audience pin failed (non-fatal): $($_.Exception.Message)"
}

# --- Acquire a USER (delegated) token for the publish call ---
# The Foundry Microsoft 365 publish orchestration performs an on-behalf-of (OBO) exchange
# with the CALLER's token to submit the app to the M365 catalog. A managed-identity /
# service-principal token has no user context to exchange, so the publish step fails
# server-side with a bare HTTP 502 (Step 3 PATCH, which does not OBO, still succeeds under
# MSI). It MUST be a delegated user token, so acquire one here on the azd host (a user) and
# pass it to the VM script, which uses it instead of the VM's IMDS managed-identity token.
Write-Host '[postdeploy] Acquiring a user access token for the publish call (aud https://ai.azure.com)...'
$publishToken = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($publishToken)) {
  throw "[postdeploy] Failed to acquire an access token. Run 'az login' as a user (not a service principal)."
}
# Sanity-check that this is a delegated user token, not an app-only token - Foundry's OBO
# publish step rejects app-only tokens (502). Decode the JWT payload and inspect idtyp/upn.
try {
  $payloadSeg = $publishToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
  switch ($payloadSeg.Length % 4) { 2 { $payloadSeg += '==' } 3 { $payloadSeg += '=' } }
  $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payloadSeg)) | ConvertFrom-Json
  $claimNames = $claims.PSObject.Properties.Name
  if ($claims.idtyp -eq 'app' -or -not ($claimNames -contains 'upn' -or $claimNames -contains 'unique_name')) {
    Write-Warning "[postdeploy] The acquired token looks app-only (idtyp='$($claims.idtyp)'). Foundry's publish OBO step needs a USER token, so publish may fail with HTTP 502. Run 'az login' interactively as a user."
  }
  else {
    Write-Host "[postdeploy] Using delegated user token (upn=$($claims.upn))."
  }
}
catch {
  Write-Warning "[postdeploy] Could not decode the access token to verify it is a user token: $($_.Exception.Message)"
}

# --- Steps 3+4: enable activity protocol + publish (on the VM) ---
Write-Host "[postdeploy] Steps 3+4: publishing agent '$agentName' to Teams / M365 (scope=$publishScope)..."
$publishOut = Invoke-OnVm -ScriptParameters @(
  'Mode=Publish',
  "FoundryProjectEndpoint=$projectEndpoint",
  "AgentName=$agentName",
  "BotServiceArmId=$botArmId",
  "AccessToken=$publishToken",
  "DisplayName=$displayName",
  "PublishScope=$publishScope",
  "AppVersion=$appVersion",
  "ShortDescription=$shortDesc",
  "FullDescription=$fullDesc",
  "DeveloperName=$developerName",
  "DeveloperWebsiteUrl=$developerUrl",
  "PrivacyUrl=$privacyUrl",
  "TermsOfUseUrl=$termsUrl"
)
Write-Host '----- publish-teams (Publish) output -----'
Write-Host $publishOut
Write-Host '------------------------------------------'
if ($publishOut -notmatch '\[publish-teams\] Done\.') {
  throw '[postdeploy] Agent publish did not complete successfully. See VM output above.'
}

Write-Host "[postdeploy] Teams / M365 publish complete. Bot: $botName, scope: $publishScope."
Write-Host '[postdeploy] Find the agent in the Teams / M365 Copilot store (Shared -> "Your agents"; Tenant -> "Built by your org" after admin approval).'
