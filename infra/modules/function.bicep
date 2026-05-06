// =====================================================================
// modules/function.bicep
// Flex Consumption (FC1) Function App on Linux + Python 3.11.
// Deployment storage configured via functionAppConfig.deployment.storage
// using managed-identity (userAssigned/systemAssigned) — per FC1 best
// practice. We use systemAssigned identity throughout.
// =====================================================================
param functionAppName string
param planName string
param location string
param tags object

@description('Storage account hosting the deployment package container.')
param storageAccountName string

@description('Container inside the storage account that holds the deployment package.')
param deploymentContainerName string

@secure()
param appInsightsConnectionString string

@description('APIM gateway URL, e.g. https://<apim>.azure-api.net (no trailing slash).')
param apimGatewayUrl string

@description('Path segment of the Speech-to-Text API on APIM (e.g. "speech").')
param sttApiPath string

// ---------- Flex Consumption plan ----------
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true // Linux
  }
}

// ---------- Existing storage account (for blobEndpoint reference) ----------
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// ---------- Function App (FC1) ----------
resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: union(tags, { 'azd-service-name': 'api' })
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
    }
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccount.name
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'APIM_GATEWAY_URL'
          value: apimGatewayUrl
        }
        {
          name: 'APIM_STT_PATH'
          value: sttApiPath
        }
      ]
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
    }
  }
}

output id string = functionApp.id
output name string = functionApp.name
output principalId string = functionApp.identity.principalId
output defaultHostname string = functionApp.properties.defaultHostName
