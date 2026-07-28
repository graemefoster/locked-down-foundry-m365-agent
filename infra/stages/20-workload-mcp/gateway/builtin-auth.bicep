// App Service built-in auth (EasyAuth v2) for the private MCP web app.
//
// Unlike a browser app, this endpoint is called machine-to-machine by the Foundry agent with
// a bearer token, so unauthenticated requests must return 401 (NOT redirect to a login page).
//
// Secretless: clientSecretSettingName points at OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID (set in
// app-service.bicep to the MCP web app's managed identity clientId), so built-in auth uses the
// managed identity as a federated credential instead of a real secret.

param appServiceName string

@description('Client (application) id of the guarding Entra app registration.')
param clientId string

@description('OpenID issuer of the app registration (tenant v2.0 endpoint).')
param issuer string

@description('Allowed token audience — the app registration Application ID URI (api://<appId>).')
param allowedAudience string

resource appService 'Microsoft.Web/sites@2022-03-01' existing = {
  name: appServiceName
}

resource configAuth 'Microsoft.Web/sites/config@2022-03-01' = {
  parent: appService
  name: 'authsettingsV2'
  properties: {
    globalValidation: {
      requireAuthentication: true
      // Machine-to-machine caller: reject unauthenticated requests with a 401 rather than
      // bouncing to an interactive Entra login page.
      unauthenticatedClientAction: 'Return401'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: clientId
          clientSecretSettingName: 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID'
          openIdIssuer: issuer
        }
        validation: {
          allowedAudiences: [
            allowedAudience
          ]
          // "Allow requests from any application" (client-app requirement): do NOT set
          // allowedApplications — an empty [] is interpreted as "allow no application" and
          // blocks every caller. Leaving it unset + allowedPrincipals:{} allows any app.
          // "Allow requests only from the issuer tenant" is enforced by the tenant-specific
          // openIdIssuer above (login.microsoftonline.com/<tenantId>/v2.0).
          defaultAuthorizationPolicy: {
            allowedPrincipals: {}
          }
        }
      }
    }
    login: {
      tokenStore: {
        enabled: false
      }
    }
  }
}
