/*
  ==========================================================================
  Agent-subnet VNet flow logs (+ Traffic Analytics).
  ==========================================================================
  NSG flow logs are retired (no new logs can be created after 2025-06-30, full
  retirement 2027-09-30), so this uses the successor VNet flow logs to track
  what the locked-down agent subnet is actually sending/dropping — invaluable
  for spotting over-blocking after the deny-by-default switch.

  The flow log resource is a child of the regional Network Watcher, which Azure
  auto-provisions as NetworkWatcher_<region> in the NetworkWatcherRG resource
  group. This module is therefore deployed AT THAT resource group's scope (see
  the module call in main.bicep). The backing storage account lives in the main
  resource group and is passed in by id.

  Docs:
    - VNet flow logs: https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview
    - NSG flow logs retirement: https://learn.microsoft.com/azure/network-watcher/nsg-flow-logs-overview
  ==========================================================================
*/

@description('Azure region (used to resolve the regional Network Watcher name).')
param location string

@description('Resource id of the target subnet (the locked-down agent subnet) to capture flow logs for.')
param targetSubnetId string

@description('Resource id of the storage account that will hold the raw flow logs.')
param flowLogsStorageId string

@description('Name for the flow log resource.')
param flowLogName string

@description('Log Analytics workspace resource id for Traffic Analytics.')
param workspaceResourceId string

@description('Log Analytics workspace customer id (GUID) for Traffic Analytics.')
param workspaceGuid string

@description('Region of the Log Analytics workspace for Traffic Analytics.')
param workspaceRegion string

@description('Retention in days for raw flow logs in storage.')
param retentionDays int = 30

// Regional Network Watcher auto-created by the platform in NetworkWatcherRG.
resource networkWatcher 'Microsoft.Network/networkWatchers@2023-11-01' existing = {
  name: 'NetworkWatcher_${location}'
}

resource flowLog 'Microsoft.Network/networkWatchers/flowLogs@2023-11-01' = {
  parent: networkWatcher
  name: flowLogName
  location: location
  properties: {
    targetResourceId: targetSubnetId
    storageId: flowLogsStorageId
    enabled: true
    retentionPolicy: {
      days: retentionDays
      enabled: true
    }
    format: {
      type: 'JSON'
      version: 2
    }
    flowAnalyticsConfiguration: {
      networkWatcherFlowAnalyticsConfiguration: {
        enabled: true
        workspaceResourceId: workspaceResourceId
        workspaceId: workspaceGuid
        workspaceRegion: workspaceRegion
        trafficAnalyticsInterval: 10
      }
    }
  }
}

output flowLogId string = flowLog.id
