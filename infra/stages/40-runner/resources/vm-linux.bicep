/*
  Linux worker VM (Ubuntu 24.04 LTS) — the in-VNet workhorse.
  ----------------------------------------------------------
  This VM is ALWAYS deployed and owns both in-VNet jobs:

    1. In-VNet self-hosted GitHub Actions runner host for agent deploys / Teams publishing /
       MCP compliance (.github/workflows/*.yml -> scripts/create-agent.ps1 etc.). It is the only
       host that can reach the PRIVATE Foundry endpoint.
    2. Self-hosted GitHub Actions runner host (see vm-runner-extension.bicep).

  Why Linux and not the Windows dev VM (vm.bicep):
    The microsoft/ai-agent-evals action is Linux-only in practice — its composite
    steps declare `shell: bash` and pass ${{ github.action_path }} unquoted, which
    breaks on Windows backslash paths. Running the runner on Linux lets the eval
    workflow consume the action directly instead of checking it out by hand, and
    removes the Git-for-Windows / Python-MSI bootstrap entirely (apt provides both).

  The Windows VM still exists (optionally) purely for the human "RDP + Edge to see
  the environment behind the firewall" experience, and holds no private-plane RBAC.

  Boot diagnostics use the managed (platform) storage account, so no bootdiags
  storage account is needed here.

  Dependencies (pwsh, python3, azure-cli, git, jq) are installed by cloud-init at
  first boot — see cloud-init-linux-vm.yaml. All the repo's automation scripts stay
  in PowerShell and run on pwsh; only this ~10-line OS bootstrap is shell.
*/

@description('Username for the Virtual Machine.')
param adminUsername string

@description('Password for the Virtual Machine.')
@minLength(12)
@secure()
param adminPassword string

@description('Size of the virtual machine. Small by default — this box only runs the runner + run-commands.')
param vmSize string = 'Standard_D2s_v6'

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Name of the virtual machine.')
param vmName string

param virtualNetworkName string
param subnetName string

resource nic 'Microsoft.Network/networkInterfaces@2022-05-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, subnetName)
          }
        }
      }
    ]
  }
}

// @onlyIfNotExists: this VM is created once and then reused as the long-lived in-VNet runner
// host. Its osProfile.customData (cloud-init) is IMMUTABLE on an existing VM — ARM rejects any
// in-place change with PropertyChangeNotAllowed — so once the box exists we must NOT re-emit it.
// This decorator makes the deployment a no-op when the VM already exists, so editing
// cloud-init-linux-vm.yaml (or any other VM property) no longer breaks a re-`azd provision`. To
// pick up cloud-init changes, delete the VM first so it is recreated.
@onlyIfNotExists()
resource vm 'Microsoft.Compute/virtualMachines@2022-03-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      // Password auth over Bastion SSH keeps parity with the Windows VM's RDP creds
      // (one credential to manage). There is no public IP and no inbound NSG rule.
      linuxConfiguration: {
        disablePasswordAuthentication: false
        provisionVMAgent: true
      }
      customData: base64(loadTextContent('cloud-init-linux-vm.yaml'))
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 128
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

output vmName string = vm.name
output vmPrincipalId string = vm.identity.principalId
