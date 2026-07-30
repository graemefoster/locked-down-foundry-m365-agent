/*
  Model-Gateway: Foundry agent token-governance policy (config-driven)
  --------------------------------------------------------------------
  Attaches the inbound policy to the foundry-agents Responses API (structure from
  apim-foundry-agents-api.bicep). The policy does three things, in order:

    1. validate-azure-ad-token  — the caller MUST present a valid Entra token for this
       tenant (and, when callerAudience is set, that audience). The parsed token is kept
       in the `jwt` variable; the caller identity is read from it (NOT re-parsed).
    2. llm-emit-token-metric   — emits per-call token usage to Application Insights
       (the `appinsights-logger` already wired in apim.bicep), dimensioned by agent +
       caller email + caller appid, for cost attribution. The Responses hop returns
       agent-level `usage`, so this "just works" on that traffic.
    3. deny-by-default llm-token-limit — a <choose> whose <when> branches each match ONE
       (agent, caller) pair from agents/<name>/limits.json and apply that pair's token budget
       (tokens-per-minute, optional token-quota). Any caller/agent not listed falls through
       to <otherwise> and is rejected 403. Allowed callers fall past the <choose> to the
       backend routing (APIM MI -> Foundry over the private endpoint).

  Config-as-data: the allowlist is name-only + human-authored per agent
  (agents/<name>/limits.json). The deploy-agent-limits workflow AGGREGATES every limits.json
  into one `agentLimits` object and passes it here; 'azd provision' omits it (default {}) so a
  fresh environment is DENY-ALL until the workflow runs — the same posture as MCP compliance.
  Unlike MCP, NO data-plane resolution is needed: caller identities (emails / appids) are known
  at authoring time and the agent is selected in the request body, so this is a static apply.

  Escaping (identical convention to apim-mcp-compliance.bicep): single-quoted Bicep strings
  (Bicep does NOT interpolate ${} inside '''...'''), so per-branch XML is built by direct
  interpolation of resolved values; C# string quotes inside XML attributes are emitted as the
  &quot; entity so they don't prematurely close the attribute.
*/

@description('Name of the existing APIM instance hosting the foundry-agents API.')
param apimName string

@description('APIM API resource name to attach the policy to (matches apim-foundry-agents-api.bicep apiName).')
param apiName string = 'foundry-agents'

@description('Name of the primary Foundry (Cognitive Services) account — used to derive the backend entity ID (must match the api module).')
param foundryAccountName string

@description('Entra tenant ID the caller token must be issued by.')
param tenantId string = subscription().tenantId

@description('Optional audience the caller Entra token must carry (e.g. api://<clientId> of your agent-facing app registration). Empty = validate tenant + signature only. NOTE: even when empty, access is still gated by the deny-by-default allowlist below (an unlisted email/appid gets 403), so an audience is defence-in-depth against token reuse from another resource rather than the primary gate. Set it in hardened environments.')
param callerAudience string = ''

@description('Application Insights metric namespace for the emitted token metrics.')
param metricNamespace string = 'foundry-agent-tokens'

@description('Backend Responses path the caller path is rewritten to (the public /<account>/<project> prefix is dropped). Default is the OpenAI v1 Responses surface.')
param backendResponsesPath string = '/openai/v1/responses'

@description('Resource the APIM managed identity requests a backend token for (keyless Foundry data-plane auth).')
param backendAuthResource string = 'https://ai.azure.com'

@description('AGGREGATED per-agent token-limit allowlist. Omit (default {}) to apply DENY-ALL (locked until the deploy-agent-limits workflow runs). Shape: { metricNamespace?, agents: [ { agentRef, principals: [ { email?, appId?, tokensPerMinute, tokenQuota?, tokenQuotaPeriod? } ] } ] }. agentRef "*" matches any agent.')
param agentLimits object = {}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName

  resource agentsApi 'apis@2024-06-01-preview' existing = {
    name: apiName
  }
}

var backendId = 'foundry-agents-${foundryAccountName}'
var metricNs = agentLimits.?metricNamespace ?? metricNamespace
var agents = agentLimits.?agents ?? []

// --- Caller-identity variable expressions (read once from the validated `jwt`) ----------------
// Email: preferred_username (v2) -> upn (v1) -> email; AppId: appid (v1) -> azp (v2). All
// lowercased so the allowlist compare is case-insensitive. Agent: best-effort read of the
// request body's agent selector (agent_id -> agent -> model), lowercased.
var jwtEmailExpr = '((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;preferred_username&quot;, ((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;upn&quot;, ((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;email&quot;, string.Empty))).ToLowerInvariant()'
var jwtAppIdExpr = '((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;appid&quot;, ((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;azp&quot;, string.Empty)).ToLowerInvariant()'
var bodyAgentExpr = '@{ try { var b = context.Request.Body?.As<JObject>(preserveContent: true); if (b == null) { return string.Empty; } var v = (string)(b[&quot;agent_id&quot;] ?? b[&quot;agent&quot;] ?? b[&quot;model&quot;]); return (v ?? string.Empty).ToLowerInvariant(); } catch { return string.Empty; } }'

// Condition-side variable reads (the set-variable results).
var callerEmailVar = '((string)context.Variables[&quot;callerEmail&quot;])'
var callerAppIdVar = '((string)context.Variables[&quot;callerAppId&quot;])'
var callerAgentVar = '((string)context.Variables[&quot;callerAgent&quot;])'

// --- Normalise the config before building XML ------------------------------------------------
// Defence-in-depth (the deploy-agent-limits workflow ALSO validates limits.json before calling
// this module): lowercase + strip the two characters (&quot; and backslash) that could break out
// of the C# string literals / XML attributes the values are interpolated into, coerce the numeric
// budgets through int(), and DROP any principal that carries neither an email nor an appId (so the
// identity ternary below always has a claim to match and can never dereference a missing property).
var normalizedAgents = map(agents, a => {
  agentRef: replace(replace(toLower(string(a.agentRef)), '"', ''), '\\', '')
  isWildcard: string(a.agentRef) == '*'
  principals: map(filter(a.principals, p => contains(p, 'email') || contains(p, 'appId')), p => {
    email: contains(p, 'email') ? replace(replace(toLower(string(p.email)), '"', ''), '\\', '') : ''
    appId: contains(p, 'appId') ? replace(replace(toLower(string(p.appId)), '"', ''), '\\', '') : ''
    hasEmail: contains(p, 'email')
    hasAppId: contains(p, 'appId')
    tpm: string(int(p.?tokensPerMinute ?? 0))
    quota: contains(p, 'tokenQuota') ? ' token-quota="${string(int(p.tokenQuota))}" token-quota-period="${replace(replace(string(p.?tokenQuotaPeriod ?? 'Daily'), '"', ''), '\\', '')}"' : ''
  })
})

// Precedence: emit SPECIFIC-agent branches first and wildcard (agentRef "*") branches LAST. APIM's
// <choose> takes the FIRST matching <when>, so an unordered wildcard could otherwise shadow (and
// apply a looser budget than) a stricter per-agent rule for the same caller.
var orderedAgents = concat(filter(normalizedAgents, a => !a.isWildcard), filter(normalizedAgents, a => a.isWildcard))

// --- Per-(agent, principal) <when> branches -------------------------------------------------
// Flatten agents x principals into one branch list. Each branch matches the caller-agent
// (unless wildcard) AND the principal's identity (email, appId, or BOTH for OBO), then applies
// that pair's llm-token-limit with a namespaced counter-key.
var branchLists = map(orderedAgents, a => map(a.principals, p => format(
  '      <when condition="@({0})">\n        <llm-token-limit counter-key="fatl:{1}:{2}" tokens-per-minute="{3}"{4} estimate-prompt-tokens="true" remaining-tokens-header-name="x-tokens-remaining" tokens-consumed-header-name="x-tokens-consumed" />\n      </when>\n',
  // {0} full match condition: [agent AND] principal
  concat(
    (a.isWildcard ? '' : '${callerAgentVar} == &quot;${a.agentRef}&quot; && '),
    ((p.hasEmail && p.hasAppId)
      ? '(${callerEmailVar} == &quot;${p.email}&quot; && ${callerAppIdVar} == &quot;${p.appId}&quot;)'
      : (p.hasEmail
          ? '${callerEmailVar} == &quot;${p.email}&quot;'
          : '${callerAppIdVar} == &quot;${p.appId}&quot;'))
  ),
  // {1} agent key for the counter-key namespace
  (a.isWildcard ? 'any' : a.agentRef),
  // {2} principal key for the counter-key namespace
  ((p.hasEmail && p.hasAppId) ? '${p.email}|${p.appId}' : (p.hasEmail ? p.email : p.appId)),
  // {3} tokens-per-minute
  p.tpm,
  // {4} optional token-quota attributes
  p.quota
)))
var whenBranches = join(flatten(branchLists), '')

// DENY-BY-DEFAULT 403. Reused wrapped in <otherwise> when there ARE allow branches, and standalone
// (no <choose>) when there are NONE — an APIM <choose> with only <otherwise> is INVALID.
var denyResponseXml = '<return-response>\n          <set-status code="403" reason="Forbidden" />\n          <set-header name="Content-Type" exists-action="override">\n            <value>application/json</value>\n          </set-header>\n          <set-body>{"error":"caller_not_permitted","message":"This caller identity is not authorized (or has no token budget) for this agent. Add it under the agent in agents/&lt;name&gt;/limits.json and re-run the deploy-agent-limits workflow."}</set-body>\n        </return-response>'

var governanceXml = empty(flatten(branchLists))
  ? '    ${denyResponseXml}\n'
  : '    <choose>\n${whenBranches}      <otherwise>\n        ${denyResponseXml}\n      </otherwise>\n    </choose>\n'

// Optional audience block for validate-azure-ad-token.
var audiencesBlock = empty(callerAudience)
  ? ''
  : '\n      <audiences>\n        <audience>${callerAudience}</audience>\n        <audience>${callerAudience}/</audience>\n      </audiences>'

// Backend routing (only reached by allowed callers — the <otherwise>/standalone 403 stops the
// pipeline before it for denied callers). APIM authenticates to Foundry with its own MI (keyless).
var backendRoutingXml = '    <set-backend-service backend-id="${backendId}" />\n    <authentication-managed-identity resource="${backendAuthResource}" />\n    <rewrite-uri template="${backendResponsesPath}" copy-unmatched-params="true" />\n'

var policyXml = '<policies>\n  <inbound>\n    <base />\n    <validate-azure-ad-token tenant-id="${tenantId}" header-name="Authorization" output-token-variable-name="jwt" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized: caller token failed validation.">${audiencesBlock}\n    </validate-azure-ad-token>\n    <set-variable name="callerEmail" value="@(${jwtEmailExpr})" />\n    <set-variable name="callerAppId" value="@(${jwtAppIdExpr})" />\n    <set-variable name="callerAgent" value="${bodyAgentExpr}" />\n    <llm-emit-token-metric namespace="${metricNs}">\n      <dimension name="AgentRef" value="@(${callerAgentVar})" />\n      <dimension name="CallerEmail" value="@(${callerEmailVar})" />\n      <dimension name="CallerAppId" value="@(${callerAppIdVar})" />\n      <dimension name="ApiId" value="@(context.Api.Id)" />\n    </llm-emit-token-metric>\n${governanceXml}${backendRoutingXml}  </inbound>\n  <backend>\n    <base />\n  </backend>\n  <outbound>\n    <base />\n  </outbound>\n  <on-error>\n    <base />\n  </on-error>\n</policies>'

resource agentLimitsPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: apim::agentsApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: policyXml
  }
}

@description('Number of (agent, caller) token-limit branches applied (0 = deny-all).')
output governedBranchCount int = length(flatten(branchLists))

@description('The API the token-governance policy was applied to.')
output appliedToApi string = apiName
