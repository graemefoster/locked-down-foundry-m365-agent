/*
Agents capability host — the Foundry-specific resource that turns a plain project into one
that can run the Agents service against BYO (bring-your-own) backing stores.

A "capability host" is a child of both the account and the project that tells Foundry WHICH
connections to use for agent state: the thread/message store (CosmosDB), the file store
(Storage) and the vector store (AI Search). Without it, the project's BYO connections exist
but the Agents runtime has nothing wiring them together.

Hard ordering rule: this MUST be created AFTER the project identity has the data-plane roles
on Cosmos/Storage/Search (Foundry validates access when the host is created), and the
container-scope roles (Blob Data Owner, Cosmos data contributor) are granted AFTER it, because
they target containers the capability host provisions. The stage 15 orchestrator enforces both.
*/

param cosmosDBConnection string 
param azureStorageConnection string 
param aiSearchConnection string
param projectName string
param accountName string
param projectCapHost string

var threadConnections = ['${cosmosDBConnection}']
var storageConnections = ['${azureStorageConnection}']
var vectorStoreConnections = ['${aiSearchConnection}']


resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
   name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  name: projectName
  parent: account
}

resource projectCapabilityHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview' = {
  name: projectCapHost
  parent: project
  properties: {
    capabilityHostKind: 'Agents'
    vectorStoreConnections: vectorStoreConnections
    storageConnections: storageConnections
    threadStorageConnections: threadConnections
  }

}

output projectCapHost string = projectCapabilityHost.name
