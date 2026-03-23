// ==========================================================
// Azure On-Prem Nested Lab (Level 1) - main.bicep
// Deploys: VNet/Subnet + UDR + HVHOST (nested virtualization host)
// Default region: eastus3
// Recommended size: Standard_D32s_v5 (32 vCPU / 128 GiB)
// Access: JIT via Defender for Cloud (documented in README, not deployed here)
// ==========================================================

targetScope = 'resourceGroup'

@description('Location for all resources. Default: East US 3 (eastus3).')
param location string = 'eastus3'

@description('Prefix used for resource naming.')
param prefix string = 'onprem'

@description('HVHOST virtual machine name.')
param hvhostName string = 'HVHOST'

@description('Admin username for HVHOST.')
param adminUsername string

@description('Admin password for HVHOST.')
@secure()
param adminPassword string

@description('VM size for HVHOST. Must support nested virtualization. Recommended: Standard_D32s_v5.')
param hvhostVmSize string = 'Standard_D32s_v5'

@description('Windows image SKU for HVHOST. Recommended: 2022-datacenter (Desktop Experience).')
@allowed([
  '2022-datacenter'
  '2022-datacenter-azure-edition'
  '2019-datacenter'
])
param hvhostWindowsSku string = '2022-datacenter'

@description('Virtual network address space.')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Subnet for Azure VMs (where HVHOST NIC1 will be placed).')
param azureVmsSubnetPrefix string = '10.0.1.0/24'

@description('Subnet for Hyper-V LAN (HVHOST NIC2). Used as next hop for UDR.')
param hypervLanSubnetPrefix string = '10.0.0.0/24'

@description('Nested (on-prem simulated) address space used inside HVHOST. Used by UDR.')
param nestedSubnetPrefix string = '10.0.2.0/24'

@description('Data disk size for HVHOST in GB (stores nested VMs, VHDs, ISOs).')
@minValue(256)
@maxValue(4095)
param hvhostDataDiskSizeGB int = 1024

@description('Enable a public IP for HVHOST. Keep false when using JIT + no direct RDP exposure.')
param enablePublicIp bool = true

@description('Resource tags applied to all resources.')
param tags object = {
  workload: 'azure-onprem-nested-lab'
  owner: 'lab'
}

// --------------------------
// Derived names
// --------------------------
var vnetName = '${prefix}-vnet'
var azureVmsSubnetName = 'Azure-VMs'
var hypervLanSubnetName = 'HyperV-LAN'
var udrName = '${prefix}-udr-azurevms'

// --------------------------
// Modules
// --------------------------
module network './modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    vnetName: vnetName
    vnetAddressPrefix: vnetAddressPrefix
    azureVmsSubnetName: azureVmsSubnetName
    azureVmsSubnetPrefix: azureVmsSubnetPrefix
    hypervLanSubnetName: hypervLanSubnetName
    hypervLanSubnetPrefix: hypervLanSubnetPrefix
    tags: tags
  }
}

module udr './modules/udr.bicep' = {
  name: 'udr'
  params: {
    location: location
    udrName: udrName
    // Route: nested subnet (10.0.2.0/24) via HVHOST NIC2 (10.0.0.4 by default from hvhost module output)
    nestedSubnetPrefix: nestedSubnetPrefix
    nextHopIp: hvhost.outputs.hypervLanNicPrivateIp
    subnetIdToAssociate: network.outputs.azureVmsSubnetId
    tags: tags
  }
  dependsOn: [
    network
  ]
}

module hvhost './modules/hvhost.bicep' = {
  name: 'hvhost'
  params: {
    location: location
    hvhostName: hvhostName
    adminUsername: adminUsername
    adminPassword: adminPassword
    hvhostVmSize: hvhostVmSize
    hvhostWindowsSku: hvhostWindowsSku

    vnetId: network.outputs.vnetId
    azureVmsSubnetId: network.outputs.azureVmsSubnetId
    hypervLanSubnetId: network.outputs.hypervLanSubnetId

    hvhostDataDiskSizeGB: hvhostDataDiskSizeGB
    enablePublicIp: enablePublicIp
    tags: tags

    // Used by the host bootstrap script to configure nested networking
    nestedSubnetPrefix: nestedSubnetPrefix
  }
  dependsOn: [
    network
  ]
}

// --------------------------
// Outputs
// --------------------------
@description('HVHOST resource name.')
output hvhostVmName string = hvhostName

@description('HVHOST private IP on Azure-VMs subnet (NIC1).')
output hvhostAzureVmsIp string = hvhost.outputs.azureVmsNicPrivateIp

@description('HVHOST private IP on HyperV-LAN subnet (NIC2).')
output hvhostHypervLanIp string = hvhost.outputs.hypervLanNicPrivateIp

@description('VNet name.')
output vnetDeployedName string = vnetName

@description('Nested subnet prefix used inside HVHOST.')
output nestedPrefix string = nestedSubnetPrefix
