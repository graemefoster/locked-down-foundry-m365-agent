/*
  Model-Gateway: MCP compliance wrapper (config-driven, FQDN-free)
  ---------------------------------------------------------------
  Applies the per-agent rate-limit compliance policy to EVERY MCP server listed in
  mcp/mcp.json, by instantiating apim-mcp-compliance.bicep in a loop. Each server's
  allowlist is read (inside that module) from its block in mcp/mcp-policy.json.

  This wrapper needs NO backend FQDNs - only APIM control-plane inputs - so it is the
  single module used by BOTH:
    * main.bicep (at 'azd up' provision time, so a fresh environment starts compliant), and
    * the deploy-compliancy workflow (on-demand re-apply after editing the JSON),
  keeping one source of truth for the applied policy across both paths.
*/

@description('Name of the existing APIM instance hosting the MCP APIs.')
param apimName string

@description('Audience the MCP AgenticIdentityToken is minted for (the MCP app registration audience). Shared across servers for now; flowed from the deployment.')
param mcpAudience string

@description('Entra tenant ID the caller token must be issued by.')
param tenantId string = subscription().tenantId

@description('Path (relative to this module) to the MCP servers config that decides WHICH servers get a policy. Each per-server allowlist is read from mcp/mcp-policy.json inside the per-server module.')
param mcpConfig object = loadJsonContent('../../../mcp/mcp.json')

// One compliance policy per configured MCP server. Sequenced so the policy PUTs do not
// race each other on the same APIM instance.
@batchSize(1)
module policies 'apim-mcp-compliance.bicep' = [for server in mcpConfig.servers: {
  name: 'mcp-compliance-${server.name}-deployment'
  params: {
    apimName: apimName
    serverName: server.name
    mcpAudience: mcpAudience
    tenantId: tenantId
  }
}]

@description('Number of MCP servers a compliance policy was applied to.')
output governedServerCount int = length(mcpConfig.servers)
