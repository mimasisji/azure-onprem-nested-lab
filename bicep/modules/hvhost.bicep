// ==========================================================
// hvhost.bicep
// Creates:
// - Optional Standard Public IP
// - 2 NICs (Azure-VMs + HyperV-LAN) with IP forwarding enabled
// - HVHOST VM + data disk
// - Custom Script Extension to bootstrap Hyper-V + nested networking
// Outputs:
// - azureVmsNicPrivateIp
// - hypervLanNicPrivateIp
// ==========================================================

@description('Location for compute resources.')
param location string

@description('HVHOST virtual machine name.')
param hvhostName string

@description('Admin username for HVHOST.')
param adminUsername string

@description('Admin password for HVHOST.')
@secure()
param adminPassword string

@description('VM size for HVHOST. Must support nested virtualization.')
param hvhostVmSize string

@description('Windows Server image SKU (e.g., 2022-datacenter).')
param hvhostWindowsSku string

@description('Azure-VMs subnet resource ID (NIC1).')
param azureVmsSubnetId string

@description('HyperV-LAN subnet resource ID (NIC2).')
param hypervLanSubnetId string

@description('Data disk size for HVHOST in GB (stores nested VMs, VHDs, ISOs).')
param hvhostDataDiskSizeGB int

@description('Enable a public IP for HVHOST. Use JIT to avoid always-open RDP.')
param enablePublicIp bool

@description('Tags applied to resources.')
param tags object

@description('Nested subnet prefix used inside HVHOST (used by bootstrap script). Example: 10.0.2.0/24')
param nestedSubnetPrefix string

@description('Raw URL to the hvhostsetup.ps1 script in your GitHub repo (raw.githubusercontent.com).')
param hvhostSetupScriptUri string = 'https://raw.githubusercontent.com/CHANGE_ME/azure-onprem-nested-lab/main/scripts/hvhostsetup.ps1'

// --------------------------
// Names
// --------------------------
var pipName = '${toLower(hvhostName)}-pip'
var nic1Name = '${toLower(hvhostName)}-nic1'
var nic2Name = '${toLower(hvhostName)}-nic2'
var dataDiskName = '${toLower(hvhostName)}-datadisk'
var extName = 'bootstrap-hvhost'

// --------------------------
// Optional Public IP (Standard SKU)
// --------------------------
resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (enablePublicIp) {
  name: pipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// --------------------------
// NIC1 (Azure-VMs)
// --------------------------
resource nic1 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: nic1Name
  location: location
  tags: tags
  properties: {
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: azureVmsSubnetId
          }
          publicIPAddress: enablePublicIp ? {
            id: pip.id
          } : null
        }
      }
    ]
  }
}

// --------------------------
// NIC2 (HyperV-LAN)
// --------------------------
resource nic2 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: nic2Name
  location: location
  tags: tags
  properties: {
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: hypervLanSubnetId
          }
        }
      }
    ]
  }
}

// --------------------------
// Data Disk (Managed Disk)
// --------------------------
resource dataDisk 'Microsoft.Compute/disks@2024-07-01' = {
  name: dataDiskName
  location: location
  tags: tags
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    creationData: {
      createOption: 'Empty'
    }
    diskSizeGB: hvhostDataDiskSizeGB
  }
}

// --------------------------
// HVHOST VM
// --------------------------
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: hvhostName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: hvhostVmSize
    }
    osProfile: {
      computerName: hvhostName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: hvhostWindowsSku
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          name: dataDisk.name
          createOption: 'Attach'
          managedDisk: {
            id: dataDisk.id
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic1.id
          properties: {
            primary: true
          }
        }
        {
          id: nic2.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
    // NOTE: nested virtualization compatibility can be affected by Trusted Launch settings.
    // We'll document using Security Type "Standard" in README for reliability.
  }
}

// --------------------------
// Custom Script Extension (bootstrap Hyper-V + NAT/RRAS)
// --------------------------
resource cse 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  name: '${vm.name}/${extName}'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: [
        hvhostSetupScriptUri
      ]
      commandToExecute: 'powershell -ExecutionPolicy Bypass -File hvhostsetup.ps1 -NestedSubnetPrefix "${nestedSubnetPrefix}"'
    }
    protectedSettings: {}
  }
  dependsOn: [
    vm
  ]
}

// --------------------------
// Outputs (Private IPs for UDR / troubleshooting)
// --------------------------
@description('HVHOST private IP on Azure-VMs subnet (NIC1).')
output azureVmsNicPrivateIp string = nic1.properties.ipConfigurations[0].properties.privateIPAddress

@description('HVHOST private IP on HyperV-LAN subnet (NIC2). Used as next hop for UDR.')
output hypervLanNicPrivateIp string = nic2.properties.ipConfigurations[0].properties.privateIPAddress
