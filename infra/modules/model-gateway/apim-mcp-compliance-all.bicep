/*
  Model-Gateway: MCP compliance wrapper (config-driven, FQDN-free)
  ---------------------------------------------------------------
  Applies the per-agent rate-limit compliance policy to EVERY MCP server listed in
  mcp/mcp.json, by instantiating apim-mcp-compliance.bicep in a loop.

  The allowlist (mcp/mcp-policy.json) is name-only in the repo; agent names are resolved to
  AppIds at DEPLOY time (agents don't exist until seeded post-provision). This wrapper takes
  the RESOLVED policy as the mcpPolicy parameter and threads it to each per-server module:
    * main.bicep (at 'azd up' provision time) omits mcpPolicy -> this wrapper builds a
      DENY-ALL default (every server in mcp.json with an empty agent list), so a fresh
      environment is locked down until access is explicitly granted; and
    * the deploy-compliancy workflow resolves names -> AppIds on the in-VNet runner and
      passes the enriched policy in, so agents actually gain their configured rate limits.
  Both paths use this ONE module, keeping a single source of truth for the applied policy.
*/

@description('Name of the existing APIM instance hosting the MCP APIs.')
param apimName string

@description('Audience the MCP AgenticIdentityToken is minted for (the MCP app registration audience). Shared across servers for now; flowed from the deployment.')
param mcpAudience string

@description('Entra tenant ID the caller token must be issued by.')
param tenantId string = subscription().tenantId

@description('Path (relative to this module) to the MCP servers config that decides WHICH servers exist. Used to build the deny-all default when no resolved mcpPolicy is supplied.')
param mcpConfig object = loadJsonContent('../../../mcp/mcp.json')

@description('RESOLVED (AppId-enriched) MCP rate-limit policy. Omit (default {}) to apply DENY-ALL for every server in mcpConfig -- the correct posture at provision time, before agents are seeded. The deploy-compliancy workflow supplies the resolved policy after agents exist. Shape: { renewalPeriodSeconds, servers: [ { name, agents: [ { name, appId, requestsPerMinute } ] } ] }.')
param mcpPolicy object = {}

// When no resolved policy is supplied (azd provision), synthesise a deny-all policy: every MCP
// server from mcp.json present with an empty agents[] -> each per-server <choose> has no allow
// branch -> unconditional 403. This CANNOT be a param default because param defaults may not
// reference other params (mcpConfig), so it is derived here as a var.
var effectivePolicy = empty(mcpPolicy)
  ? { renewalPeriodSeconds: 60, servers: map(mcpConfig.servers, s => { name: s.name, agents: [] }) }
  : mcpPolicy

// One compliance policy per configured MCP server. Sequenced so the policy PUTs do not
// race each other on the same APIM instance. Each per-server module filters effectivePolicy
// by serverName itself, so the whole resolved policy is threaded in.
@batchSize(1)
module policies 'apim-mcp-compliance.bicep' = [for server in mcpConfig.servers: {
  name: 'mcp-compliance-${server.name}-deployment'
  params: {
    apimName: apimName
    serverName: server.name
    mcpAudience: mcpAudience
    tenantId: tenantId
    mcpPolicy: effectivePolicy
  }
}]

@description('Number of MCP servers a compliance policy was applied to.')
output governedServerCount int = length(mcpConfig.servers)
