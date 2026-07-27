/*
  Model-Gateway: MCP per-agent rate-limit compliance policy
  ---------------------------------------------------------
  Reflects mcp/mcp-policy.json into an APIM policy on the MCP API so that each
  Foundry agent's MCP tool calls are rate-limited by the agent's AppId. This is the
  "MCP governance" layer of the AI gateway, authored explicitly as IaC (no portal
  magic) and driven by a single repo-tracked config file.

  Auth posture (defense-in-depth, additive to the App Service EasyAuth backend):
    * validate-azure-ad-token runs at the APIM edge and validates the caller's
      AgenticIdentityToken against the MCP app registration audience + this tenant.
      The token is still forwarded UNCHANGED to the backend (pass-through preserved),
      so App Service built-in auth continues to validate it too.
    * The caller AppId is read from the validated JWT (`appid` in v1.0 tokens, else
      `azp` in v2.0 tokens — Entra emits the agent identity's app id in one of these).
    * DENY-BY-DEFAULT: a <choose> matches each listed AppId and applies that agent's
      rate-limit-by-key (429 when exceeded). Any unlisted AppId falls through to
      <otherwise> and is rejected with HTTP 403.

  rate-limit-by-key is supported on APIM v2 tiers (token-bucket algorithm); it is NOT
  available on the Consumption tier. This gateway is Standard v2, so it is supported.

  Config-as-data: the policy XML is generated from mcp-policy.json via join(map(...)).
  Normal single-quoted Bicep strings interpolate ${...}, so (unlike apim-api-policy.bicep,
  which uses triple-quoted strings + @@TOKEN@@ replace) the per-agent branches are built
  by direct interpolation of the JSON values (guids + ints, no XML-escaping hazard).
*/

@description('Name of the existing APIM instance hosting the MCP API.')
param apimName string

@description('Name of the existing MCP API on APIM (the apimMcpApi module output apiName; defaults to "mcp").')
param mcpApiName string = 'mcp'

@description('Audience the MCP AgenticIdentityToken is minted for (the MCP app registration audience, e.g. api://<clientId>).')
param mcpAudience string

@description('Entra tenant ID the caller token must be issued by.')
param tenantId string = subscription().tenantId

@description('Path (relative to this module) to the MCP rate-limit config. Override to point at an alternate config file.')
param mcpPolicyConfig object = loadJsonContent('../../../mcp/mcp-policy.json')

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName

  resource mcpApi 'apis@2024-06-01-preview' existing = {
    name: mcpApiName
  }
}

var renewalPeriod = string(mcpPolicyConfig.?renewalPeriodSeconds ?? 60)

// Per-agent <when> branches: match the validated caller AppId variable and apply that
// agent's rate-limit-by-key. counter-key is namespaced ('mcp-rl:<appId>') so it never
// collides with any other rate-limit counters on this gateway.
// NOTE 1: single-quoted Bicep strings (with \n escapes) are used throughout because Bicep
//   does NOT interpolate ${...} inside triple-quoted ('''...''') strings.
// NOTE 2: APIM policy expressions are C#, so string literals use double quotes. Those live
//   inside XML attributes (also double-quoted), so every C# string quote is emitted as the
//   XML entity &quot; (a plain double quote would prematurely close the attribute). In a
//   Bicep single-quoted string, both " and &quot; are literal; only ' needs escaping.
var whenBranches = join(map(mcpPolicyConfig.agents, agent => '      <when condition="@(((string)context.Variables[&quot;callerAppId&quot;]).ToLowerInvariant() == &quot;${toLower(agent.appId)}&quot;)">\n        <rate-limit-by-key calls="${string(agent.requestsPerMinute)}" renewal-period="${renewalPeriod}" counter-key="@(&quot;mcp-rl:&quot; + ((string)context.Variables[&quot;callerAppId&quot;]).ToLowerInvariant())" remaining-calls-header-name="x-mcp-ratelimit-remaining" />\n      </when>\n'), '')

// DENY-BY-DEFAULT: any AppId not listed above is rejected with 403.
var otherwiseBranch = '      <otherwise>\n        <return-response>\n          <set-status code="403" reason="Forbidden" />\n          <set-header name="Content-Type" exists-action="override">\n            <value>application/json</value>\n          </set-header>\n          <set-body>{"error":"agent_not_permitted","message":"This agent identity is not authorized to call the MCP gateway. Add its AppId to mcp/mcp-policy.json and re-run the deploy-compliancy workflow."}</set-body>\n        </return-response>\n      </otherwise>\n'

// The AppId claim: prefer `appid` (v1.0 tokens), fall back to `azp` (v2.0 tokens).
// Read from the Jwt object that validate-azure-ad-token already parsed + validated
// (output-token-variable-name="mcpJwt"). This preserves the chain of trust — we never
// re-parse the raw Authorization header — and cannot throw or 500 on a malformed header,
// since the request is already rejected with 401 before this expression runs.
var callerAppIdExpr = '@(((Jwt)context.Variables[&quot;mcpJwt&quot;]).Claims.GetValueOrDefault(&quot;appid&quot;, ((Jwt)context.Variables[&quot;mcpJwt&quot;]).Claims.GetValueOrDefault(&quot;azp&quot;, string.Empty)))'

var mcpPolicyXml = '<policies>\n  <inbound>\n    <base />\n    <validate-azure-ad-token tenant-id="${tenantId}" header-name="Authorization" output-token-variable-name="mcpJwt" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized: MCP token failed validation.">\n      <audiences>\n        <audience>${mcpAudience}</audience>\n        <audience>${mcpAudience}/</audience>\n      </audiences>\n    </validate-azure-ad-token>\n    <set-variable name="callerAppId" value="${callerAppIdExpr}" />\n    <choose>\n${whenBranches}${otherwiseBranch}    </choose>\n  </inbound>\n  <backend>\n    <base />\n  </backend>\n  <outbound>\n    <base />\n  </outbound>\n  <on-error>\n    <base />\n  </on-error>\n</policies>'

resource mcpCompliancePolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: apim::mcpApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: mcpPolicyXml
  }
}

@description('Number of agents governed by the applied policy.')
output governedAgentCount int = length(mcpPolicyConfig.agents)

@description('The MCP API the compliance policy was applied to.')
output appliedToApi string = mcpApiName
