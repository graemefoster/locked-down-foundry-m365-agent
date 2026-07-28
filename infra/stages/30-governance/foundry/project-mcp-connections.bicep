/*
Project MCP connections — one Foundry project connection per governed MCP server.

Split out of ai-project-identity.bicep (project CREATION) so these connections can be
created in a later stage: they are "Not used by a capability host", so they have no
ordering dependency on the Agents capability host and need not run at project-create time.

Each connection's target is the server's APIM gateway URL; the agent reaches its MCP tools
through the gateway using this connection's AgenticIdentity token, minted for that server's
audience. Looping (rather than a single scalar connection) means there is no "primary"
server to special-case — every server is wired symmetrically.
*/

param accountName string
param projectName string

@description('MCP project connections to create — one per governed MCP server (from mcp/mcp.json). Each item is { name, url, audience }: name = the Foundry connection name; url = the APIM gateway URL the agent calls (trailing slash included); audience = the AgenticIdentityToken audience (an Entra app registration you control, not a Microsoft one). The array is authored in main.bicep from the APIM server outputs, so adding a server here needs no module change.')
param mcpConnections array

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
  scope: resourceGroup()
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: account
  name: projectName
}

resource project_connection_mcp_server 'Microsoft.CognitiveServices/accounts/projects/connections@2026-03-01' = [for c in mcpConnections: {
  parent: project
  name: c.name
  properties: {
    category: 'RemoteTool'
    target: c.url
    authType: 'AgenticIdentityToken'
    audience: c.audience
    group: 'GenericProtocol'
    metadata: {
      type: 'custom_MCP'
    }
  }
}]
