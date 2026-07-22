<#
  Publish a seeded Foundry agent to Teams / M365 (runs ON the private VM)
  ----------------------------------------------------------------------
  Executed on the locked-down VM (inside the private VNet) by the azd `postdeploy`
  hook (hooks/postdeploy.ps1) via `az vm run-command`, because Steps 1/3/4 call the
  PRIVATE Foundry endpoint that only the VM can reach.

  Ref: https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot-virtual-network

  Two modes (the hook needs the agent identity BEFORE it can create the bot):

    -Mode GetIdentity : Step 1 — GET the agent, print instance_identity.principal_id /
                        client_id as parseable markers for the host hook.
    -Mode Publish     : Step 3 — PATCH the agent to add the `activity` protocol +
                        BotServiceRbac scheme (keeping responses + Entra), then
                        Step 4 — POST the Microsoft 365 publish API with the bot ARM ID.

  Idempotent: re-running GetIdentity is read-only; the PATCH is a merge-patch; and a
  publish of an already-published appVersion ("version already exists") is treated as
  success. Prints '[publish-teams] Done.' only on success (the host gates on this marker).
#>
param(
  [Parameter(Mandatory = $true)]  [ValidateSet('GetIdentity', 'Publish')] [string]$Mode,
  [Parameter(Mandatory = $true)]  [string]$FoundryProjectEndpoint,
  [Parameter(Mandatory = $true)]  [string]$AgentName,

  # Publish-only parameters
  [Parameter(Mandatory = $false)] [string]$BotServiceArmId = '',
  [Parameter(Mandatory = $false)] [string]$DisplayName = '',
  [Parameter(Mandatory = $false)] [string]$PublishScope = 'Shared',
  [Parameter(Mandatory = $false)] [string]$AppVersion = '1.0.0',
  [Parameter(Mandatory = $false)] [string]$ShortDescription = 'Foundry M365 agent',
  [Parameter(Mandatory = $false)] [string]$FullDescription = 'A Foundry agent published to Microsoft 365 from a locked-down virtual network.',
  [Parameter(Mandatory = $false)] [string]$DeveloperName = 'Azure Developer',
  [Parameter(Mandatory = $false)] [string]$DeveloperWebsiteUrl = 'https://azure.microsoft.com',
  [Parameter(Mandatory = $false)] [string]$PrivacyUrl = 'https://privacy.microsoft.com',
  [Parameter(Mandatory = $false)] [string]$TermsOfUseUrl = 'https://www.microsoft.com/legal/terms-of-use',

  # Optional caller-supplied bearer token for the https://ai.azure.com audience.
  # When empty (default) the VM's own managed identity token (IMDS) is used, which is fine
  # for the read/PATCH steps (GetIdentity, activity-protocol enable). The Step 4 publish
  # call, however, triggers an on-behalf-of exchange in Foundry to submit the app to the
  # M365 catalog, which REQUIRES a delegated USER token - an app-only / managed-identity
  # token fails server-side with HTTP 502. The postdeploy hook acquires a user token on the
  # host and passes it here for the Publish invocation.
  [Parameter(Mandatory = $false)] [string]$AccessToken = ''
)
$ErrorActionPreference = 'Stop'

# Strip trailing slash so /agents never becomes //agents.
$FoundryProjectEndpoint = $FoundryProjectEndpoint.TrimEnd('/')

function Get-FoundryToken {
  $response = Invoke-RestMethod `
    -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fai.azure.com%2F' `
    -Headers @{ Metadata = 'true' } `
    -Method Get
  return $response.access_token
}

Write-Host "[publish-teams] Mode=$Mode Agent=$AgentName"
Write-Host "[publish-teams] Endpoint: $FoundryProjectEndpoint"

if (-not [string]::IsNullOrWhiteSpace($AccessToken)) {
  $token = $AccessToken.Trim()
  Write-Host '[publish-teams] Using caller-supplied access token (user identity).'
}
else {
  $token = Get-FoundryToken
  Write-Host '[publish-teams] Token acquired (VM managed identity).'
}
$authHeader = @{ Authorization = "Bearer $token" }

if ($Mode -eq 'GetIdentity') {
  # --- Step 1: get the agent identity ---
  $agent = Invoke-RestMethod `
    -Method Get `
    -Uri "$FoundryProjectEndpoint/agents/$AgentName`?api-version=v1" `
    -Headers ($authHeader + @{ 'Content-Type' = 'application/json' })

  $principalId = $agent.instance_identity.principal_id
  $clientId    = $agent.instance_identity.client_id
  if ([string]::IsNullOrWhiteSpace($principalId)) {
    throw "[publish-teams] Agent '$AgentName' has no instance_identity.principal_id (agent.identity is null). See the Foundry agent migration guide."
  }

  # Parseable markers the host hook greps for.
  Write-Host "[publish-teams] PRINCIPAL_ID=$principalId"
  Write-Host "[publish-teams] CLIENT_ID=$clientId"
  Write-Host '[publish-teams] Done.'
  return
}

# --- Mode Publish ---
if ([string]::IsNullOrWhiteSpace($BotServiceArmId)) {
  throw '[publish-teams] Publish mode requires -BotServiceArmId.'
}

# --- Step 3: enable the activity protocol + BotServiceRbac (keep responses + Entra) ---
Write-Host '[publish-teams] Step 3: enabling activity protocol + BotServiceRbac...'
$patchBody = @{
  agent_endpoint = @{
    protocol_configuration = @{
      responses = @{}
      activity  = @{}
    }
    authorization_schemes = @(
      @{ type = 'Entra' }
      @{ type = 'BotServiceRbac' }
    )
  }
} | ConvertTo-Json -Depth 10 -Compress

Invoke-RestMethod `
  -Method Patch `
  -Uri "$FoundryProjectEndpoint/agents/$AgentName`?api-version=v1" `
  -Headers ($authHeader + @{ 'Content-Type' = 'application/merge-patch+json'; 'Foundry-Features' = 'AgentEndpoints=V1Preview' }) `
  -Body $patchBody | Out-Null
Write-Host '[publish-teams] Step 3 complete.'

# --- Step 4: publish to Microsoft 365 ---
Write-Host "[publish-teams] Step 4: publishing (scope=$PublishScope, version=$AppVersion)..."
$publishBody = @{
  botServiceArmId     = $BotServiceArmId
  publishScope        = $PublishScope
  publishAsAutopilot  = $false
  appVersion          = $AppVersion
  shortDescription    = $ShortDescription
  fullDescription     = $FullDescription
  developerName       = $DeveloperName
  developerWebsiteUrl = $DeveloperWebsiteUrl
  privacyUrl          = $PrivacyUrl
  termsOfUseUrl       = $TermsOfUseUrl
}
if (-not [string]::IsNullOrWhiteSpace($DisplayName)) {
  $publishBody['agentDisplayName'] = $DisplayName
}
$publishJson = $publishBody | ConvertTo-Json -Depth 10 -Compress

# The microsoft365/publish orchestration is a long-running server-side flow that can
# return transient 5xx (502/503/504) while it spins up. Retry those with backoff;
# treat "version already exists" as an idempotent success and surface the response
# body for any other terminal error so it is actually diagnosable.
$maxAttempts = 5
$published   = $false
for ($attempt = 1; $attempt -le $maxAttempts -and -not $published; $attempt++) {
  try {
    $result = Invoke-RestMethod `
      -Method Post `
      -Uri "$FoundryProjectEndpoint/agents/$AgentName/microsoft365/publish?api-version=v1" `
      -Headers ($authHeader + @{ 'Content-Type' = 'application/json' }) `
      -Body $publishJson
    Write-Host "[publish-teams] Published. titleId=$($result.titleId)"
    $published = $true
  }
  catch {
    $status = $null
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    $detail = ''
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }

    # Re-publishing an existing appVersion is a no-op success for our idempotency purposes.
    if ($detail -match 'version already exists') {
      Write-Host "[publish-teams] appVersion '$AppVersion' already published - treating as success. Increment TEAMS_APP_VERSION to publish user-facing changes."
      $published = $true
    }
    elseif ($status -in 502, 503, 504 -and $attempt -lt $maxAttempts) {
      $wait = [math]::Min(30, [math]::Pow(2, $attempt))
      Write-Host "[publish-teams] Publish attempt $attempt returned HTTP $status (transient). Retrying in ${wait}s..."
      Start-Sleep -Seconds $wait
    }
    else {
      Write-Host "[publish-teams] Publish failed (HTTP $status) after $attempt attempt(s)."
      if ($detail) { Write-Host "[publish-teams] Response body: $detail" }
      throw
    }
  }
}

Write-Host '[publish-teams] Done.'
