// ---------------------------------------------------------------------------
// Module: role-assignments.bicep
// Deploys: RBAC role assignments for the Function App's Managed Identity
//          scoped to the resource group containing Arc machines
// ---------------------------------------------------------------------------

@description('Principal ID of the Function App Managed Identity.')
param principalId string

// Built-in role definition IDs
// See: https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles
var roles = {
  // Azure Connected Machine Resource Administrator — covers assessPatches + installPatches
  connectedMachineResourceAdmin: 'cd570a14-e51a-42ad-bac8-bafd67325302'
  // Reader — for Resource Graph queries, reading maintenance configurations
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  // Monitoring Reader — for Resource Health availability statuses
  monitoringReader: '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
}

var scope = resourceGroup().id

resource connectedMachineAdminAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(scope, principalId, roles.connectedMachineResourceAdmin)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.connectedMachineResourceAdmin)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(scope, principalId, roles.reader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.reader)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource monitoringReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(scope, principalId, roles.monitoringReader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.monitoringReader)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
