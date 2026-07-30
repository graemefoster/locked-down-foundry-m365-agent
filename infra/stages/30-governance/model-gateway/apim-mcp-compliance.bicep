/*
  Model-Gateway: MCP per-agent rate-limit compliance policy (one server)
  ----------------------------------------------------------------------
  Reflects the RESOLVED mcpPolicy block for ONE MCP server into an APIM policy on
  that server's API, so each Foundry agent's MCP tool calls are rate-limited by the
  agent's AppId. This is the "MCP governance" layer of the AI gateway, authored
  explicitly as IaC (no portal magic). apim-mcp-compliance-all.bicep instantiates
  this module once per server in mcp/mcp.json, threading in the resolved policy.

  The policy is name-only in the repo (mcp/mcp-policy.json). Agent names are resolved
  to AppIds at DEPLOY time (deploy-agent-network workflow -> scripts/list-agent-appids.ps1)
  because agent identities don't exist until the agents are seeded post-provision. The
  resolved (AppId-enriched) policy is passed in via the mcpPolicy parameter; 'azd provision'
  passes a deny-all default because it runs before any agent exists.

  Server-keyed + per-server: mcpPolicy.servers[] is looked up by `serverName`;
  only that server's agents[] become allow branches. A server with no block here (or
  an agent not listed under it) is denied on this API - allowing on one server never
  implies allowing on another.

  Auth posture (defense-in-depth, additive to the App Service EasyAuth backend):
    * validate-azure-ad-token runs at the APIM edge and validates the caller's
      AgenticIdentityToken against the MCP app registration audience + this tenant.
      The token is still forwarded UNCHANGED to the backend (pass-through preserved),
      so App Service built-in auth continues to validate it too.
    * The caller AppId is read from the validated JWT (`appid` in v1.0 tokens, else
      `azp` in v2.0 tokens - Entra emits the agent identity's app id in one of these).
    * DENY-BY-DEFAULT: a <choose> matches each listed AppId and applies that agent's
      rate-limit-by-key (429 when exceeded). Any unlisted AppId falls through to
      <otherwise> and is rejected with HTTP 403.

  rate-limit-by-key is supported on APIM v2 tiers (token-bucket algorithm); it is NOT
  available on the Consumption tier. This gateway is Standard v2, so it is supported.

  Config-as-data: the policy XML is generated from the resolved mcpPolicy param via
  join(map(...)). Normal single-quoted Bicep strings interpolate ${...}, so (unlike
  apim-api-policy.bicep, which uses triple-quoted strings + @@TOKEN@@ replace) the per-agent
  branches are built by direct interpolation of the resolved values (guids + ints, no
  XML-escaping hazard).
*/

@description('Name of the existing APIM instance hosting the MCP API.')
param apimName string

@description('MCP server name = the APIM API name to attach the policy to (matches mcp/mcp.json and the key in mcp/mcp-policy.json.servers[]).')
param serverName string

@description('Audience the MCP AgenticIdentityToken is minted for (the MCP app registration audience, e.g. api://<clientId>). Flowed in from the deployment; shared across servers for now.')
param mcpAudience string

@description('Entra tenant ID the caller token must be issued by.')
param tenantId string = subscription().tenantId

@description('RESOLVED MCP rate-limit policy (AppId-enriched). Threaded in from apim-mcp-compliance-all.bicep, which either builds a deny-all default (azd provision, before agents are seeded) or receives the deploy-time-resolved policy from the deploy-agent-network workflow. Shape: { renewalPeriodSeconds, servers: [ { name, agents: [ { name, appId, requestsPerMinute } ] } ] }. Defaults to {} (deny-all) so a direct invocation without a policy is safe.')
param mcpPolicy object = {}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName

  resource mcpApi 'apis@2024-06-01-preview' existing = {
    name: serverName
  }
}

var renewalPeriod = string(mcpPolicy.?renewalPeriodSeconds ?? 60)

// Look up THIS server's allowlist. A server absent from mcpPolicy (or present with no
// agents) yields an empty list -> the <choose> has no <when> branches -> everything hits the
// <otherwise> 403 (deny-by-default), which is the correct posture for an ungoverned server.
var serverMatches = filter(mcpPolicy.?servers ?? [], s => s.name == serverName)
var agentsForServer = empty(serverMatches) ? [] : (first(serverMatches).?agents ?? [])

// Per-agent <when> branches: match the validated caller AppId variable and apply that
// agent's rate-limit-by-key. counter-key is namespaced ('mcp-rl:<server>:<appId>') so it never
// collides with any other rate-limit counters on this gateway or across servers.
// NOTE 1: single-quoted Bicep strings (with \n escapes) are used throughout because Bicep
//   does NOT interpolate ${...} inside triple-quoted ('''...''') strings.
// NOTE 2: APIM policy expressions are C#, so string literals use double quotes. Those live
//   inside XML attributes (also double-quoted), so every C# string quote is emitted as the
//   XML entity &quot; (a plain double quote would prematurely close the attribute). In a
//   Bicep single-quoted string, both " and &quot; are literal; only ' needs escaping.
var whenBranches = join(map(agentsForServer, agent => '      <when condition="@(((string)context.Variables[&quot;callerAppId&quot;]).ToLowerInvariant() == &quot;${toLower(agent.appId)}&quot;)">\n        <rate-limit-by-key calls="${string(agent.requestsPerMinute)}" renewal-period="${renewalPeriod}" counter-key="@(&quot;mcp-rl:${serverName}:&quot; + ((string)context.Variables[&quot;callerAppId&quot;]).ToLowerInvariant())" remaining-calls-header-name="x-mcp-ratelimit-remaining" />\n      </when>\n'), '')

// DENY-BY-DEFAULT: any AppId not listed above is rejected with 403. The return-response block
// is reused in two shapes: wrapped in <otherwise> when there ARE allow branches, and emitted
// standalone (no <choose>) when there are NONE - because APIM requires a <choose> to contain at
// least one <when>, a <choose> with only <otherwise> is INVALID and would fail policy apply.
var denyResponseXml = '<return-response>\n          <set-status code="403" reason="Forbidden" />\n          <set-header name="Content-Type" exists-action="override">\n            <value>application/json</value>\n          </set-header>\n          <set-body>{"error":"agent_not_permitted","message":"This agent identity is not authorized to call this MCP server. Add its AppId under this server in mcp/mcp-policy.json and re-run the deploy-agent-network workflow."}</set-body>\n        </return-response>'
var otherwiseBranch = '      <otherwise>\n        ${denyResponseXml}\n      </otherwise>\n'

// The governance block placed inside <inbound>: a <choose> (>=1 allow <when> + deny <otherwise>)
// when this server has allowed agents, else an unconditional 403 return-response (deny-all) so we
// never emit an invalid empty <choose>. Both paths are strictly deny-by-default.
var governanceXml = empty(agentsForServer)
  ? '    ${denyResponseXml}\n'
  : '    <choose>\n${whenBranches}${otherwiseBranch}    </choose>\n'

// The AppId claim: prefer `appid` (v1.0 tokens), fall back to `azp` (v2.0 tokens).
// Read from the Jwt object that validate-azure-ad-token already parsed + validated
// (output-token-variable-name="mcpJwt"). This preserves the chain of trust - we never
// re-parse the raw Authorization header - and cannot throw or 500 on a malformed header,
// since the request is already rejected with 401 before this expression runs.
var callerAppIdExpr = '@(((Jwt)context.Variables[&quot;mcpJwt&quot;]).Claims.GetValueOrDefault(&quot;appid&quot;, ((Jwt)context.Variables[&quot;mcpJwt&quot;]).Claims.GetValueOrDefault(&quot;azp&quot;, string.Empty)))'

var mcpPolicyXml = '<policies>\n  <inbound>\n    <base />\n    <validate-azure-ad-token tenant-id="${tenantId}" header-name="Authorization" output-token-variable-name="mcpJwt" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized: MCP token failed validation.">\n      <audiences>\n        <audience>${mcpAudience}</audience>\n        <audience>${mcpAudience}/</audience>\n      </audiences>\n    </validate-azure-ad-token>\n    <set-variable name="callerAppId" value="${callerAppIdExpr}" />\n${governanceXml}  </inbound>\n  <backend>\n    <base />\n  </backend>\n  <outbound>\n    <base />\n  </outbound>\n  <on-error>\n    <base />\n  </on-error>\n</policies>'

resource mcpCompliancePolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: apim::mcpApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: mcpPolicyXml
  }
}

@description('Number of agents allowed on this server by the applied policy.')
output governedAgentCount int = length(agentsForServer)

@description('The MCP server/API the compliance policy was applied to.')
output appliedToApi string = serverName
