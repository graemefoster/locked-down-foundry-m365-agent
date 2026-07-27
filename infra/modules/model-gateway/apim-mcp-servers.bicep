/*
  Model-Gateway: MCP servers wrapper (config-driven)
  --------------------------------------------------
  Compiles mcp/mcp.json into the APIM AI gateway: one `type: mcp` API + backend
  per listed server, by instantiating apim-mcp-api.bicep in a loop. This is the
  "which MCP servers does the gateway front" layer, authored as IaC (no portal
  magic) and driven by a single repo-tracked config file.

  Backend FQDNs are NOT stored in mcp/mcp.json (they are generated at provision
  time). They are flowed in here via `serverFqdns`, a { <serverName>: <fqdn> } map
  the caller (main.bicep) builds from the App Service deployment outputs. Each
  server entry's backend path defaults to /<name> by convention; a server may
  override it with an optional `backendPath` field (used to retrofit the existing
  sample, whose deployed backend is served at /mcp).
*/

@description('Name of the existing APIM instance hosting the MCP APIs.')
param apimName string

@description('Map of { <serverName>: <mcpWebAppFqdn> } flowed from the deployment. Every server in mcp/mcp.json MUST have a matching key here (the FQDN is generated at provision time, so it cannot live in the config file).')
param serverFqdns object

@description('Path (relative to this module) to the MCP servers config. Override to point at an alternate config file.')
param mcpConfig object = loadJsonContent('../../../mcp/mcp.json')

// One APIM MCP API + backend per configured server. Backend path is /<name> by
// convention unless the entry supplies an explicit `backendPath`.
module mcpApis 'apim-mcp-api.bicep' = [for server in mcpConfig.servers: {
  name: 'mcp-api-${server.name}-deployment'
  params: {
    apimName: apimName
    serverName: server.name
    mcpWebAppFqdn: serverFqdns[server.name]
    backendPath: server.?backendPath ?? '/${server.name}'
  }
}]

@description('The MCP servers exposed on APIM, as [{ name, url }] — url is the gateway URL Foundry connects to.')
output servers array = [for (server, i) in mcpConfig.servers: {
  name: server.name
  url: mcpApis[i].outputs.mcpGatewayUrl
}]
