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
