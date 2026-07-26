/*
  Azure Bastion — browser/CLI access to the VMs behind the firewall.
  -----------------------------------------------------------------
  Extracted from vm.bicep so it is independent of the OPTIONAL Windows dev VM:
  the always-on Linux worker VM (vm-linux.bicep) is reachable over Bastion SSH
  for troubleshooting even when deployWindowsVm=false.
*/

@description('Location for the Bastion host.')
param location string = resourceGroup().location

@description('Name of the VNet the Bastion is deployed into (must contain AzureBastionSubnet).')
param virtualNetworkName string

@description('Name of the Bastion host.')
param bastionName string = 'agent-vnet-test-bastion'

resource bastion 'Microsoft.Network/bastionHosts@2025-01-01' = {
  name: bastionName
  location: location
  sku: { name: 'Developer' }
  properties: {
    virtualNetwork: {
      id: resourceId('Microsoft.Network/virtualNetworks', virtualNetworkName)
    }
  }
}

output bastionName string = bastion.name
