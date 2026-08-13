/*
Stage 10 slice — Data-resource private endpoints & DNS.
AI Search, Storage, CosmosDB, ACR and Key Vault all get private endpoints; the
privatelink DNS zones are linked to the hub VNet for the DNS resolver. The Foundry
account PE lives with the account in stage 13. The MCP web app PE lives in stage 20
(with the MCP workload); the YARP proxy is the public ingress, so it never gets a
private endpoint.
*/

param uniqueSuffix string

@description('Deploy the STANDARD tier BYO stores private endpoints (Search/Storage/Cosmos). False = BASIC tier: only the always-on ACR + Key Vault PEs.')
param deployStandardAgent bool

// Dependent-resource names (from the data-resources slice). The trio names are empty in the
// BASIC tier (no BYO stores); their PEs are gated off inside the inner module.
param aiSearchName string
param storageName string
param cosmosDBName string
param acrName string
param keyVaultName string

// From stage 00 networking.
param foundrySpokeVnetName string
param foundryPeSubnetName string

// Private DNS zone ids (created early in stage 00).
param aiSearchDnsZoneId string
param storageDnsZoneId string
param cosmosDBDnsZoneId string
param acrDnsZoneId string
param keyVaultDnsZoneId string

module privateEndpointAndDNS './network/private-endpoint-and-dns.bicep' = {
  name: '${uniqueSuffix}-private-endpoint'
  params: {
    deployStandardAgent: deployStandardAgent
    aiSearchName: aiSearchName
    storageName: storageName
    cosmosDBName: cosmosDBName

    // Foundry Spoke (Foundry PEs go here)
    foundrySpokeVnetName: foundrySpokeVnetName
    foundryPeSubnetName: foundryPeSubnetName

    // Private DNS zone ids (created early in stage 00)
    aiSearchDnsZoneId: aiSearchDnsZoneId
    storageDnsZoneId: storageDnsZoneId
    cosmosDBDnsZoneId: cosmosDBDnsZoneId
    acrDnsZoneId: acrDnsZoneId
    keyVaultDnsZoneId: keyVaultDnsZoneId

    acrName: acrName
    keyVaultName: keyVaultName
  }
}
