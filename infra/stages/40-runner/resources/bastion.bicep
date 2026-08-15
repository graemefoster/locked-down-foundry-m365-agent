/*
  Azure Bastion — browser access to the VMs behind the firewall.
  --------------------------------------------------------------
  Extracted from vm.bicep and gated by main.bicep's `deployBastion` param, which
  DEFAULTS to `deployWindowsVm`. Bastion is an INTERACTIVE-access concern only:
    * Windows dev VM  -> Bastion is the only way in (RDP), so it must be deployed.
    * Linux worker VM -> needs no interactive path. Agent seeding goes through
      `az vm run-command` and the Actions runner registers OUTBOUND, so a CI-only
      environment (deployWindowsVm=false) skips Bastion too.
  Keeping it a separate param means you can still opt into Bastion SSH on the Linux
  VM for troubleshooting without paying for the Windows VM. The Bastion is deployed
  into the dedicated AzureBastionSubnet so the VM subnet NSG can trust that subnet
  instead of a broad VirtualNetwork source.
*/

@description('Location for the Bastion host.')
param location string = resourceGroup().location

@description('Resource ID of the dedicated AzureBastionSubnet.')
param bastionSubnetId string

@description('Name of the Bastion host.')
param bastionName string = 'agent-vnet-test-bastion'

resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${bastionName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: bastionName
  location: location
  sku: { name: 'Basic' }
  properties: {
    ipConfigurations: [
      {
        name: 'IpConf'
        properties: {
          subnet: {
            id: bastionSubnetId
          }
          publicIPAddress: {
            id: bastionPublicIp.id
          }
        }
      }
    ]
  }
}

output bastionName string = bastion.name
