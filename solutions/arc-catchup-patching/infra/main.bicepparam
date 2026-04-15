using 'main.bicep'

param location = 'eastus'
param baseName = 'arc-catchup-patching'
param offlineThresholdHours = 2
param tags = {
  solution: 'arc-catchup-patching'
  managedBy: 'bicep'
}
