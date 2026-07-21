resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = { name: 'acc' }
resource proj 'Microsoft.CognitiveServices/accounts/projects@2024-10-01' existing = { parent: account, name: 'proj' }
resource connection 'Microsoft.CognitiveServices/accounts/projects/connections@2024-10-01' = {
  parent: proj
  name: 'test'
  properties: {
    category: 'ApiManagement'
    target: 'test'
    authType: 'ApiKey'
    metadata: {
      customHeaders: {
        value: {
          'api-key': 'test'
        }
      }
    }
  }
}
