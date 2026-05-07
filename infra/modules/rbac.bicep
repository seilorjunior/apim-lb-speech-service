// =====================================================================
// modules/rbac.bicep
// Role assignments:
//   * APIM MI       -> Cognitive Services User on each Speech account
//   * Function MI   -> Storage Blob Data Owner on the storage account
//                      (required for FC1 deployment + AzureWebJobsStorage)
//   * Dev principal -> Cognitive Services User on each Speech account
//                      (only when devPrincipalId is non-empty)
//   * Dev principal -> Key Vault Secrets User on the AMR vault
//                      (only when devPrincipalId AND keyVaultName are
//                      non-empty; lets a developer inspect / rotate
//                      `redis-connection-string` from the local CLI)
// =====================================================================
param apimPrincipalId string
param functionPrincipalId string
param speechPrimaryName string
param speechSecondaryName string
param storageAccountName string

@description('Optional dev user principal ID. Empty string = skip.')
param devPrincipalId string = ''

@description('Optional Key Vault name. When non-empty AND devPrincipalId is non-empty, grants the dev principal Key Vault Secrets User on the vault. Empty string = skip (e.g., when useExternalCache=false and no vault is deployed).')
param keyVaultName string = ''

// ---- Built-in role IDs ----
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var storageBlobDataOwnerRoleId  = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var keyVaultSecretsUserRoleId   = '4633458b-17de-408a-b874-0445c86b69e6'

// ---- Existing resources (cross-module references) ----
resource speechPrimary 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: speechPrimaryName
}
resource speechSecondary 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: speechSecondaryName
}
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// ---- APIM -> Speech (primary) ----
resource apimToSpeechPrimary 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: speechPrimary
  name: guid(speechPrimary.id, apimPrincipalId, cognitiveServicesUserRoleId)
  properties: {
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
  }
}

// ---- APIM -> Speech (secondary) ----
resource apimToSpeechSecondary 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: speechSecondary
  name: guid(speechSecondary.id, apimPrincipalId, cognitiveServicesUserRoleId)
  properties: {
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
  }
}

// ---- Function MI -> Storage (Blob Data Owner) ----
resource functionToStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, functionPrincipalId, storageBlobDataOwnerRoleId)
  properties: {
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
  }
}

// ---- Optional: dev principal -> Speech accounts (for local testing) ----
resource devToSpeechPrimary 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(devPrincipalId)) {
  scope: speechPrimary
  name: guid(speechPrimary.id, devPrincipalId, cognitiveServicesUserRoleId)
  properties: {
    principalId: devPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
  }
}

resource devToSpeechSecondary 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(devPrincipalId)) {
  scope: speechSecondary
  name: guid(speechSecondary.id, devPrincipalId, cognitiveServicesUserRoleId)
  properties: {
    principalId: devPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
  }
}

// ---- Optional: dev principal -> Key Vault (Secrets User) ----
// Gated on BOTH params being supplied so the module is still safe to
// invoke when useExternalCache=false (no vault deployed) or when no
// dev principal was provided.
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = if (!empty(keyVaultName)) {
  name: keyVaultName
}

resource devToKeyVault 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(devPrincipalId) && !empty(keyVaultName)) {
  scope: keyVault
  name: guid(keyVault.id, devPrincipalId, keyVaultSecretsUserRoleId)
  properties: {
    principalId: devPrincipalId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
  }
}
