// =====================================================================
// modules/speech.bicep
// One Cognitive Services account (kind: SpeechServices, S0).
// Local auth disabled so APIM must use its managed identity.
// =====================================================================
@minLength(2)
@maxLength(64)
param name string
param location string
param tags object

resource speech 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: name
  location: location
  tags: tags
  kind: 'SpeechServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: name
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true // force AAD/MI auth
    networkAcls: {
      defaultAction: 'Allow'
    }
  }
}

output id string = speech.id
output name string = speech.name
// e.g. https://<custom-subdomain>.cognitiveservices.azure.com/
output endpoint string = speech.properties.endpoint
output location string = speech.location
