// =====================================================================
// main-resources.bicep (resource group scope)
//
// Orchestrates the modules:
//   1. monitoring (Log Analytics + App Insights)
//   2. storage    (Function App deployment storage, FC1 requirement)
//   3. speech x2  (primary + secondary regions, local auth disabled)
//   4. redis      (Azure Managed Redis used as APIM external cache)
//   5. apim       (Basic v2 + system-assigned MI + load-balanced pool + STT API
//                  + external cache pointing at AMR)
//   6. function   (Flex Consumption Python; calls APIM)
//   7. rbac       (APIM MI -> Cognitive Services User on each Speech;
//                  Function MI -> Storage Blob Data Owner on storage;
//                  optional principalId -> Cognitive Services User on Speech)
// =====================================================================
targetScope = 'resourceGroup'

@description('Primary location (RG, APIM, Function, primary Speech, Redis).')
param location string

@description('Location for the secondary Speech account.')
param secondarySpeechLocation string

@description('Deterministic resource token used to name globally-unique resources.')
param resourceToken string

@description('Common tags applied to every resource.')
param tags object

@description('Optional dev principal ID. If non-empty, gets Cognitive Services User on the Speech accounts.')
param principalId string = ''

@description('Azure Managed Redis SKU. Balanced_B0 is the cheapest dev tier (~$80/month, no SLA). Ignored when useExternalCache=false.')
param redisSkuName string = 'Balanced_B0'

@description('When true, deploys Azure Managed Redis and registers it as the APIM external cache. When false (default) APIM uses its built-in cache, which is sufficient for a single-unit BasicV2 deployment and saves ~$80/month.')
param useExternalCache bool = false

// ---------- Module: monitoring ----------
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    tags: tags
    logAnalyticsName: 'log-${resourceToken}'
    appInsightsName: 'appi-${resourceToken}'
  }
}

// ---------- Module: storage (Function App deployment container) ----------
module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    tags: tags
    storageAccountName: 'st${resourceToken}'
    deploymentContainerName: 'app-package'
  }
}

// ---------- Module: speech x2 ----------
module speechPrimary 'modules/speech.bicep' = {
  name: 'speech-primary'
  params: {
    location: location
    tags: tags
    name: 'spch-${resourceToken}-primary'
  }
}

module speechSecondary 'modules/speech.bicep' = {
  name: 'speech-secondary'
  params: {
    location: secondarySpeechLocation
    tags: tags
    name: 'spch-${resourceToken}-secondary'
  }
}

// ---------- Module: Azure Managed Redis (APIM external cache, optional) ----------
module redis 'modules/redis.bicep' = if (useExternalCache) {
  name: 'redis'
  params: {
    location: location
    tags: tags
    name: 'redis-${resourceToken}'
    skuName: redisSkuName
  }
}

// ---------- Module: APIM ----------
module apim 'modules/apim.bicep' = {
  name: 'apim'
  params: {
    location: location
    tags: tags
    apimName: 'apim-${resourceToken}'
    publisherEmail: 'admin@contoso.com'
    publisherName: 'apim-lb-speech-service'
    appInsightsId: monitoring.outputs.appInsightsId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    speechPrimaryEndpoint: speechPrimary.outputs.endpoint
    speechSecondaryEndpoint: speechSecondary.outputs.endpoint
    speechPrimaryName: speechPrimary.outputs.name
    speechSecondaryName: speechSecondary.outputs.name
    redisClusterName: redis.?outputs.name ?? ''
    redisDatabaseName: redis.?outputs.databaseName ?? 'default'
  }
}

// ---------- Module: Function App (Flex Consumption) ----------
module functionApp 'modules/function.bicep' = {
  name: 'function'
  params: {
    location: location
    tags: tags
    planName: 'plan-${resourceToken}'
    functionAppName: 'func-${resourceToken}'
    storageAccountName: storage.outputs.name
    deploymentContainerName: storage.outputs.deploymentContainerName
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    apimGatewayUrl: apim.outputs.gatewayUrl
    sttApiPath: apim.outputs.sttApiPath
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsId
  }
}

// ---------- Module: RBAC ----------
module rbac 'modules/rbac.bicep' = {
  name: 'rbac'
  params: {
    apimPrincipalId: apim.outputs.principalId
    functionPrincipalId: functionApp.outputs.principalId
    speechPrimaryName: speechPrimary.outputs.name
    speechSecondaryName: speechSecondary.outputs.name
    storageAccountName: storage.outputs.name
    devPrincipalId: principalId
  }
}

// ---- Outputs surfaced to azd ----
output apimGatewayUrl string = apim.outputs.gatewayUrl
output sttApiPath string = apim.outputs.sttApiPath
output functionAppName string = functionApp.outputs.name
output functionAppHostname string = functionApp.outputs.defaultHostname
output speechPrimaryName string = speechPrimary.outputs.name
output speechSecondaryName string = speechSecondary.outputs.name
output redisName string = redis.?outputs.name ?? ''
output redisHostName string = redis.?outputs.hostName ?? ''
