// =====================================================================
// main.bicep (subscription scope)
//
// Creates the resource group and delegates resource creation to
// `main-resources.bicep`. azd discovers this file via azure.yaml.
//
// Architecture:
//   Client -> Function App (Python, Flex Consumption)
//          -> APIM (Basic v2, system-assigned MI)
//          -> [Speech Brazil South, Speech South Central US]   (load-balanced pool)
// =====================================================================
targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment. Used to derive resource names and tags.')
param environmentName string

@description('Primary location for the resource group, APIM, Function App, and primary Speech account.')
param location string = 'brazilsouth'

@description('Location for the secondary Speech account (paired region for failover).')
param secondarySpeechLocation string = 'southcentralus'

@description('Optional principal ID of the developer running azd. If supplied, grants Cognitive Services User on Speech accounts for local testing.')
param principalId string = ''

@description('Azure Managed Redis SKU used as the APIM external cache. Balanced_B0 is the cheapest dev tier (~$80/month, no SLA). Ignored when useExternalCache=false.')
param redisSkuName string = 'Balanced_B0'

@description('When true, deploys Azure Managed Redis and registers it as the APIM external cache. When false (default) APIM uses its built-in cache. Set to true only when scaling APIM beyond a single unit.')
param useExternalCache bool = false

@description('When true, applies non-dev safety guards (currently: Key Vault purge protection). Leave false for dev / preview environments — purge protection is irreversible once enabled.')
param useProductionGuards bool = false

@description('TTL (seconds) for the APIM idempotency cache on submit-batch. Tunable per environment via the `idempotency-ttl-seconds` APIM named value created by apim.bicep. Default 3600 (1 hour).')
@minValue(60)
@maxValue(604800)
param idempotencyTtlSeconds int = 3600

// Deterministic suffix derived from subscription + env name (azd convention).
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = {
  'azd-env-name': environmentName
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources 'main-resources.bicep' = {
  name: 'resources-${resourceToken}'
  scope: rg
  params: {
    location: location
    secondarySpeechLocation: secondarySpeechLocation
    resourceToken: resourceToken
    tags: tags
    principalId: principalId
    redisSkuName: redisSkuName
    useExternalCache: useExternalCache
    useProductionGuards: useProductionGuards
    idempotencyTtlSeconds: idempotencyTtlSeconds
  }
}

// ---- Outputs consumed by azd / postprovision hook ----
output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = rg.name
output APIM_GATEWAY_URL string = resources.outputs.apimGatewayUrl
output APIM_STT_PATH string = resources.outputs.sttApiPath
output FUNCTION_APP_NAME string = resources.outputs.functionAppName
output FUNCTION_APP_HOSTNAME string = resources.outputs.functionAppHostname
output SPEECH_PRIMARY_NAME string = resources.outputs.speechPrimaryName
output SPEECH_SECONDARY_NAME string = resources.outputs.speechSecondaryName
output AZURE_REDIS_NAME string = resources.outputs.redisName
output AZURE_REDIS_HOST string = resources.outputs.redisHostName
