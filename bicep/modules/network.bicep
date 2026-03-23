// ==========================================================
// network.bicep
// Creates: Virtual Network + 2 subnets
// Outputs: vnetId, azureVmsSubnetId, hypervLanSubnetId
// ==========================================================

@description('Location for network resources.')
param location string

@description('Virtual network name.')
param vnetName string

@description('VNet address space (CIDR).')
param vnetAddressPrefix string

@description('Subnet name for Azure VMs (HVHOST NIC1).')
param azureVmsSubnetName string

@description('Subnet prefix for Azure VMs (CIDR).')
param azureVmsSubnetPrefix string

@description('Subnet name for Hyper-V LAN (HVHOST NIC2).')
param hypervLanSubnetName string

@description('Subnet prefix for Hyper-V LAN (CIDR).')
param hypervLanSubnetPrefix string

@description('Tags applied to the VNet resource.')
param tags object

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: azureVmsSubnetName
        properties: {
          addressPrefix: azureVmsSubnetPrefix
        }
      }
      {
        name: hypervLanSubnetName
        properties: {
          addressPrefix: hypervLanSubnetPrefix
        }
      }
    ]
  }
}

@description('Resource ID of the deployed VNet.')
output vnetId string = vnet.id

@description('Resource ID of the Azure-VMs subnet.')
output azureVmsSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, azureVmsSubnetName)

@description('Resource ID of the HyperV-LAN subnet.')
output hypervLanSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, hypervLanSubnetName)
