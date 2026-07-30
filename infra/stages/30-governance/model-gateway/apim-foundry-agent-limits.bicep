/*
  Model-Gateway: Foundry agent token-governance policy (config-driven)
  --------------------------------------------------------------------
  Attaches the inbound policy to the foundry-agents passthrough API (structure from
  apim-foundry-agents-api.bicep). The policy does three things, in order:

    1. validate-azure-ad-token  — the caller MUST present a valid Entra token for this
       tenant (and, when callerAudience is set, that audience). The parsed token is kept
       in the `jwt` variable; the caller identity is read from it (NOT re-parsed).
    2. llm-emit-token-metric   — emits per-call token usage to Application Insights
       (the `appinsights-logger` already wired in apim.bicep), dimensioned by agent +
       caller email + caller appid, for cost attribution. OpenAI-shaped protocol hops
       (…/openai/responses) return agent-level `usage`, so metering "just works" there;
       non-OpenAI protocols (…/invocations) carry no usage and simply emit no metric, but
       remain fully AUTH-gated (validate-jwt + the deny-by-default allowlist below).
    3. deny-by-default llm-token-limit — a <choose> whose <when> branches each match ONE
       (agent, caller) pair from agents/<name>/agent-network.json and apply that pair's token budget
       (tokens-per-minute, optional token-quota). Any caller/agent not listed falls through
       to <otherwise> and is rejected 403. Allowed callers fall past the <choose> to the
       backend routing (APIM MI -> Foundry over the private endpoint).

  The agent is read from the URL PATH (…/agents/<name>/…), not the body, so the SAME policy
  governs every protocol endpoint an agent exposes, and the backend rewrite proxies the whole
  /agents/<name>/... tail onto /api/projects/<project>/agents/<name>/endpoint/protocols/... .

  Config-as-data: the allowlist is name-only + human-authored per agent
  (agents/<name>/agent-network.json). The deploy-agent-network workflow AGGREGATES every agent-network.json
  into one `agentLimits` object and passes it here; 'azd provision' omits it (default {}) so a
  fresh environment is DENY-ALL until the workflow runs — the same posture as MCP compliance.
  Unlike MCP, NO data-plane resolution is needed: caller identities (emails / appids) are known
  at authoring time and the agent is read from the URL path, so this is a static apply.

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

@description('Name of the primary Foundry project — used to build the backend rewrite path (/api/projects/<project>/agents/...).')
param projectName string

@description('Entra tenant ID the caller token must be issued by.')
param tenantId string = subscription().tenantId

@description('Optional audience the caller Entra token must carry (e.g. api://<clientId> of your agent-facing app registration). Empty = default to backendAuthResource (the Foundry data-plane audience this API fronts) — validate-azure-ad-token has NO "tenant + signature only" mode, it requires at least one audience or client-application-id. Access is still gated primarily by the deny-by-default allowlist below (an unlisted email/appid gets 403), so the audience is defence-in-depth against token reuse from another resource. Override it (api://<clientId>) in hardened environments.')
param callerAudience string = ''

@description('Application Insights metric namespace for the emitted token metrics.')
param metricNamespace string = 'foundry-agent-tokens'

@description('Resource the APIM managed identity requests a backend token for (keyless Foundry data-plane auth).')
param backendAuthResource string = 'https://ai.azure.com'

@description('AGGREGATED per-agent token-limit allowlist. Omit (default {}) to apply DENY-ALL (locked until the deploy-agent-network workflow runs). Shape: { metricNamespace?, agents: [ { agentRef, principals: [ { email?, appId?, tokensPerMinute, tokenQuota?, tokenQuotaPeriod? } ] } ] }. agentRef "*" matches any agent.')
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
// lowercased so the allowlist compare is case-insensitive. Agent: read from the URL PATH
// (…/agents/<name>/…) — a multi-protocol passthrough addresses the agent in the path, not the
// body — so metering/throttling works for EVERY protocol (openai/responses, invocations, …).
var jwtEmailExpr = '((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;preferred_username&quot;, ((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;upn&quot;, ((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;email&quot;, string.Empty))).ToLowerInvariant()'
var jwtAppIdExpr = '((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;appid&quot;, ((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;azp&quot;, string.Empty)).ToLowerInvariant()'
// agentsPath = the URL tail from '/agents/' onwards (e.g. /agents/<name>/endpoint/protocols/openai/responses).
// This is BOTH the throttling key source (agent segment) and the backend rewrite source.
var agentsPathExpr = '@{ var p = context.Request.OriginalUrl.Path; var i = p.IndexOf(&quot;/agents/&quot;, System.StringComparison.OrdinalIgnoreCase); return i &gt;= 0 ? p.Substring(i) : string.Empty; }'
// callerAgent = the segment right after '/agents/' (…/agents/<name>/…), lowercased.
var pathAgentExpr = '@{ var ap = (string)context.Variables[&quot;agentsPath&quot;]; var s = ap.Split(new char[]{ &apos;/&apos; }, System.StringSplitOptions.RemoveEmptyEntries); return s.Length &gt;= 2 ? s[1].ToLowerInvariant() : string.Empty; }'

// Condition-side variable reads (the set-variable results).
var callerEmailVar = '((string)context.Variables[&quot;callerEmail&quot;])'
var callerAppIdVar = '((string)context.Variables[&quot;callerAppId&quot;])'
var callerAgentVar = '((string)context.Variables[&quot;callerAgent&quot;])'

// --- Normalise the config before building XML ------------------------------------------------
// Defence-in-depth (the deploy-agent-network workflow ALSO validates agent-network.json before calling
// this module): lowercase + strip the characters that could break out of the C# string literals /
// XML attributes the values are interpolated into. As well as the C# delimiters (" and backslash)
// we strip the XML markup characters & < > — because APIM decodes XML entities (e.g. &quot;) to their
// literal (") BEFORE the C# expression is evaluated, a value smuggling a literal &quot; would otherwise
// reconstruct a quote at runtime and break out of the condition. We also coerce the numeric budgets
// through int(), and DROP any principal that carries neither an email nor an appId (so the identity
// ternary below always has a claim to match and can never dereference a missing property).
func sanitize(v string) string => replace(replace(replace(replace(replace(toLower(v), '&', ''), '<', ''), '>', ''), '"', ''), '\\', '')

var normalizedAgents = map(agents, a => {
  agentRef: sanitize(string(a.agentRef))
  isWildcard: string(a.agentRef) == '*'
  principals: map(filter(a.principals, p => contains(p, 'email') || contains(p, 'appId')), p => {
    email: contains(p, 'email') ? sanitize(string(p.email)) : ''
    appId: contains(p, 'appId') ? sanitize(string(p.appId)) : ''
    hasEmail: contains(p, 'email')
    hasAppId: contains(p, 'appId')
    tpm: string(int(p.?tokensPerMinute ?? 0))
    quota: contains(p, 'tokenQuota') ? ' token-quota="${string(int(p.tokenQuota))}" token-quota-period="${sanitize(string(p.?tokenQuotaPeriod ?? 'Daily'))}"' : ''
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
var denyResponseXml = '<return-response>\n          <set-status code="403" reason="Forbidden" />\n          <set-header name="Content-Type" exists-action="override">\n            <value>application/json</value>\n          </set-header>\n          <set-body>{"error":"caller_not_permitted","message":"This caller identity is not authorized (or has no token budget) for this agent. Add it under the agent in agents/&lt;name&gt;/agent-network.json and re-run the deploy-agent-network workflow."}</set-body>\n        </return-response>'

var governanceXml = empty(flatten(branchLists))
  ? '    ${denyResponseXml}\n'
  : '    <choose>\n${whenBranches}      <otherwise>\n        ${denyResponseXml}\n      </otherwise>\n    </choose>\n'

// Audience block for validate-azure-ad-token. The policy REQUIRES at least one audience or
// client-application-id (there is no "tenant + signature only" mode), so when callerAudience is
// not overridden we fall back to backendAuthResource — the Foundry data-plane audience this API
// fronts — which a caller obtaining a token for the agents API would naturally request. The
// deny-by-default allowlist remains the primary gate; the audience is defence-in-depth.
var effectiveAudience = empty(callerAudience) ? backendAuthResource : callerAudience
var audiencesBlock = '\n      <audiences>\n        <audience>${effectiveAudience}</audience>\n        <audience>${effectiveAudience}/</audience>\n      </audiences>'

// Backend routing (only reached by allowed callers — the <otherwise>/standalone 403 stops the
// pipeline before it for denied callers). APIM authenticates to Foundry with its own MI (keyless).
// Path-preserving rewrite: the whole /agents/<name>/... tail (agentsPath) is proxied onto the
// Foundry agent endpoint /api/projects/<project>/agents/<name>/endpoint/protocols/..., so every
// protocol works unchanged. copy-unmatched-params keeps the caller's query string (?api-version=…).
var backendRewriteTemplate = '@(&quot;/api/projects/${projectName}&quot; + (string)context.Variables[&quot;agentsPath&quot;])'
var backendRoutingXml = '    <set-backend-service backend-id="${backendId}" />\n    <authentication-managed-identity resource="${backendAuthResource}" />\n    <rewrite-uri template="${backendRewriteTemplate}" copy-unmatched-params="true" />\n'

var policyXml = '<policies>\n  <inbound>\n    <base />\n    <validate-azure-ad-token tenant-id="${tenantId}" header-name="Authorization" output-token-variable-name="jwt" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized: caller token failed validation.">${audiencesBlock}\n    </validate-azure-ad-token>\n    <set-variable name="callerEmail" value="@(${jwtEmailExpr})" />\n    <set-variable name="callerAppId" value="@(${jwtAppIdExpr})" />\n    <set-variable name="agentsPath" value="${agentsPathExpr}" />\n    <set-variable name="callerAgent" value="${pathAgentExpr}" />\n    <llm-emit-token-metric namespace="${metricNs}">\n      <dimension name="AgentRef" value="@(${callerAgentVar})" />\n      <dimension name="CallerEmail" value="@(${callerEmailVar})" />\n      <dimension name="CallerAppId" value="@(${callerAppIdVar})" />\n      <dimension name="ApiId" value="@(context.Api.Id)" />\n    </llm-emit-token-metric>\n${governanceXml}${backendRoutingXml}  </inbound>\n  <backend>\n    <base />\n  </backend>\n  <outbound>\n    <base />\n  </outbound>\n  <on-error>\n    <base />\n  </on-error>\n</policies>'

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
