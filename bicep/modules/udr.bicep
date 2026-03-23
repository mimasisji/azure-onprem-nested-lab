// ==========================================================
// udr.bicep
// Creates:
// - Route Table
// - Route to nested subnet (10.0.2.0/24) via HVHOST NIC2 (Virtual Appliance)
// - Associates the route table to a subnet (Azure-VMs)
// ==========================================================

@description('Location for route table resource.')
param location string

@description('Route table name.')
param udrName string

@description('Nested subnet prefix used inside HVHOST (CIDR). Example: 10.0.2.0/24')
param nestedSubnetPrefix string

@description('Next hop IP for the nested subnet route. Should be HVHOST NIC2 IP on HyperV-LAN (e.g., 10.0.0.4).')
param nextHopIp string

@description('Subnet resource ID to associate this route table with (Azure-VMs subnet).')
param subnetIdToAssociate string

@description('Tags applied to the route table.')
param tags object

@description('Name for the route entry.')
param routeName string = 'to-nested-subnet'

// --------------------------
// Route Table
// --------------------------
resource rt 'Microsoft.Network/routeTables@2024-05-01' = {
  name: udrName
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: routeName
        properties: {
          addressPrefix: nestedSubnetPrefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: nextHopIp
        }
      }
    ]
  }
}

// --------------------------
// Associate Route Table to Subnet
// --------------------------
resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  id: subnetIdToAssociate
}

resource subnetRTA 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  name: subnet.name
  parent: subnet.parent
  properties: union(subnet.properties, {
    routeTable: {
      id: rt.id
    }
  })
}

// --------------------------
// Outputs
// --------------------------
@description('Route table resource ID.')
output routeTableId string = rt.id
