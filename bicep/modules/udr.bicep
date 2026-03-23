@description('Location for route table resource.')
param location string

@description('Route table name.')
param udrName string

@description('Nested subnet prefix used inside HVHOST (CIDR).')
param nestedSubnetPrefix string

@description('Next hop IP for the nested subnet route (HVHOST NIC2).')
param nextHopIp string

@description('Tags applied to the route table.')
param tags object

@description('Route name.')
param routeName string = 'to-nested-subnet'

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

output routeTableId string = rt.id
