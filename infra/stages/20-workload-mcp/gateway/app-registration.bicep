extension microsoftGraphV1

// Entra app registration that guards the private MCP web app via App Service built-in auth.
//
// Auth model (secretless): the MCP web app runs with a user-assigned managed identity that is
// registered here as a FEDERATED IDENTITY CREDENTIAL (MI-as-FIC). App Service built-in auth
// exchanges that MI token for a client assertion, so it can act as this app registration
// WITHOUT a client secret (see the OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID app setting in
// app-service.bicep and clientSecretSettingName in builtin-auth.bicep).
//
// The app exposes an Application ID URI (api://<appId>). The Foundry MCP connection mints an
// AgenticIdentityToken for THAT audience, which built-in auth then validates — demonstrating
// OAuth all the way from the agent to the tool endpoint.

@description('Stable unique name for the client application (uniqueName in Graph).')
param clientAppName string

@description('Friendly display name for the client application.')
param clientAppDisplayName string

@description('Principal (object) id of the MCP web app user-assigned managed identity — the FIC subject.')
param webAppIdentityPrincipalId string

param cloudEnvironment string = environment().name
param audiences object = {
  AzureCloud: {
    uri: 'api://AzureADTokenExchange'
  }
  AzureUSGovernment: {
    uri: 'api://AzureADTokenExchangeUSGov'
  }
  AzureChinaCloud: {
    uri: 'api://AzureADTokenExchangeChina'
  }
}

var issuer = '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'

resource clientApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: clientAppName
  displayName: clientAppDisplayName
  signInAudience: 'AzureADMyOrg'

  // The MCP web app's managed identity acts as this app's credential (secretless).
  resource clientAppFic 'federatedIdentityCredentials@v1.0' = {
    name: '${clientApp.uniqueName}/miAsFic'
    audiences: [
      audiences[cloudEnvironment].uri
    ]
    issuer: issuer
    subject: webAppIdentityPrincipalId
  }
}

resource clientSp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: clientApp.appId
}

output clientAppId string = clientApp.appId
output issuer string = issuer
@description('Token audience both built-in auth and the MCP connection use — the app (client) id. Entra mints the AgenticIdentityToken with this as the aud claim.')
output audience string = clientApp.appId
